package idempotency

import (
	"context"
	"errors"
	"fmt"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/pennsieve/rehydration-service/shared/dydbutils"
	"log/slog"
)

const TableNameKey = "FARGATE_IDEMPOTENT_DYNAMODB_TABLE_NAME"

type DyDBStore struct {
	client *dynamodb.Client
	table  string
	logger *slog.Logger
}

func NewStore(dyDBClient *dynamodb.Client, logger *slog.Logger, tableName string) Store {
	return &DyDBStore{
		client: dyDBClient,
		table:  tableName,
		logger: logger,
	}
}

func (s *DyDBStore) SaveInProgress(ctx context.Context, datasetID, datasetVersionID int) error {
	recordID := RecordID(datasetID, datasetVersionID)
	record := Record{
		ID:     recordID,
		Status: InProgress,
	}
	return s.PutRecord(ctx, record)
}

func (s *DyDBStore) GetRecord(ctx context.Context, recordID string) (*Record, error) {
	key := itemKeyFromRecordID(recordID)
	in := dynamodb.GetItemInput{
		Key:            key,
		TableName:      aws.String(s.table),
		ConsistentRead: aws.Bool(true),
	}
	out, err := s.client.GetItem(ctx, &in)
	if err != nil {
		return nil, fmt.Errorf("error getting record with ID %s: %w", recordID, err)
	}
	if out.Item == nil || len(out.Item) == 0 {
		return nil, nil
	}
	return FromItem(out.Item)

}

func (s *DyDBStore) PutRecord(ctx context.Context, record Record) error {
	item, err := record.Item()
	if err != nil {
		return err
	}
	putCondition := fmt.Sprintf("attribute_not_exists(%s)", KeyAttrName)
	in := dynamodb.PutItemInput{
		Item:                                item,
		TableName:                           aws.String(s.table),
		ConditionExpression:                 aws.String(putCondition),
		ReturnValuesOnConditionCheckFailure: types.ReturnValuesOnConditionCheckFailureAllOld,
	}
	if _, err = s.client.PutItem(ctx, &in); err == nil {
		return nil
	}
	var conditionFailedError *types.ConditionalCheckFailedException
	if errors.As(err, &conditionFailedError) {
		alreadyExistsError := &RecordAlreadyExistsError{}
		if existingRecord, err := FromItem(conditionFailedError.Item); err == nil {
			alreadyExistsError.Existing = existingRecord
		} else {
			alreadyExistsError.UnmarshallingError = err
		}
		return alreadyExistsError
	}
	return fmt.Errorf("error putting record %+v to %s: %w", record, s.table, err)
}

func (s *DyDBStore) UpdateRecord(ctx context.Context, record Record) error {
	asItem, err := record.Item()
	if err != nil {
		return fmt.Errorf("error marshalling record for update: %w", err)
	}
	expressionAttrNames := map[string]string{
		"#location": idempotencyRehydrationLocationAttrName,
		"#status":   idempotencyStatusAttrName,
	}
	expressionAttrValues := map[string]types.AttributeValue{
		":location": asItem[idempotencyRehydrationLocationAttrName],
		":status":   asItem[idempotencyStatusAttrName],
	}
	updateExpression := "SET #location = :location, #status = :status"

	in := &dynamodb.UpdateItemInput{
		Key:                       itemKeyFromRecordID(record.ID),
		TableName:                 aws.String(s.table),
		ExpressionAttributeNames:  expressionAttrNames,
		ExpressionAttributeValues: expressionAttrValues,
		UpdateExpression:          aws.String(updateExpression),
	}
	if _, err := s.client.UpdateItem(ctx, in); err != nil {
		return fmt.Errorf("error updating record %s: %w", record.ID, err)
	}
	return nil
}

func (s *DyDBStore) SetTaskARN(ctx context.Context, recordID string, taskARN string) error {
	expressionAttrNames := map[string]string{
		"#taskARN": idempotencyTaskARNAttrName,
	}
	expressionAttrValues := map[string]types.AttributeValue{
		":taskARN": &types.AttributeValueMemberS{Value: taskARN},
	}
	updateExpression := "SET #taskARN = :taskARN"

	in := &dynamodb.UpdateItemInput{
		Key:                       itemKeyFromRecordID(recordID),
		TableName:                 aws.String(s.table),
		ExpressionAttributeNames:  expressionAttrNames,
		ExpressionAttributeValues: expressionAttrValues,
		UpdateExpression:          aws.String(updateExpression),
	}
	if _, err := s.client.UpdateItem(ctx, in); err != nil {
		return fmt.Errorf("error setting task ARN %s on record %s: %w", taskARN, recordID, err)
	}
	return nil
}

func (s *DyDBStore) DeleteRecord(ctx context.Context, recordID string) error {
	in := &dynamodb.DeleteItemInput{
		Key:       itemKeyFromRecordID(recordID),
		TableName: aws.String(s.table),
	}
	if _, err := s.client.DeleteItem(ctx, in); err != nil {
		return fmt.Errorf("error deleting record %s: %w", recordID, err)
	}
	return nil
}

func (s *DyDBStore) ExpireRecord(ctx context.Context, recordID string) error {
	expressionAttrNames := map[string]string{
		"#status": idempotencyStatusAttrName,
	}
	expressionAttrValues := map[string]types.AttributeValue{
		":status": dydbutils.StringAttributeValue(string(Expired)),
	}
	updateExpression := "SET #status = :status"

	conditionExpression := fmt.Sprintf("attribute_exists(%s)", KeyAttrName)

	in := &dynamodb.UpdateItemInput{
		Key:                       itemKeyFromRecordID(recordID),
		TableName:                 aws.String(s.table),
		ExpressionAttributeNames:  expressionAttrNames,
		ExpressionAttributeValues: expressionAttrValues,
		UpdateExpression:          aws.String(updateExpression),
		ConditionExpression:       aws.String(conditionExpression),
	}
	if _, err := s.client.UpdateItem(ctx, in); err != nil {
		var conditionFailedError *types.ConditionalCheckFailedException
		if errors.As(err, &conditionFailedError) {
			return &RecordDoesNotExistsError{RecordID: recordID}
		}
		return fmt.Errorf("error expiring record %s: %w", recordID, err)
	}
	return nil
}

func (s *DyDBStore) LockRecordForExpiration(ctx context.Context, recordID string) error {
	return s.updateStatus(ctx, recordID, Completed, Expired)
}

func (s *DyDBStore) UnlockRecordForExpiration(ctx context.Context, recordID string) error {
	return s.updateStatus(ctx, recordID, Expired, Completed)
}

func (s *DyDBStore) updateStatus(ctx context.Context, recordID string, expectedStatus, newStatus Status) error {
	expressionAttrNames := map[string]string{
		"#status": idempotencyStatusAttrName,
	}
	expressionAttrValues := map[string]types.AttributeValue{
		":currentStatus": dydbutils.StringAttributeValue(string(expectedStatus)),
		":newStatus":     dydbutils.StringAttributeValue(string(newStatus)),
	}
	updateExpression := "SET #status = :newStatus"

	conditionExpression := fmt.Sprintf("attribute_exists(%s) AND #status = :currentStatus", KeyAttrName)

	in := &dynamodb.UpdateItemInput{
		Key:                                 itemKeyFromRecordID(recordID),
		TableName:                           aws.String(s.table),
		ExpressionAttributeNames:            expressionAttrNames,
		ExpressionAttributeValues:           expressionAttrValues,
		UpdateExpression:                    aws.String(updateExpression),
		ConditionExpression:                 aws.String(conditionExpression),
		ReturnValuesOnConditionCheckFailure: types.ReturnValuesOnConditionCheckFailureAllOld,
	}
	if _, err := s.client.UpdateItem(ctx, in); err != nil {
		var conditionFailedError *types.ConditionalCheckFailedException
		if errors.As(err, &conditionFailedError) {
			if len(conditionFailedError.Item) == 0 {
				return &RecordDoesNotExistsError{RecordID: recordID}
			}
			actualStatus := conditionFailedError.Item[idempotencyStatusAttrName].(*types.AttributeValueMemberS).Value
			return fmt.Errorf("conditional check failed while updating status of record: expected current status %s, actual status: %s", expectedStatus, actualStatus)
		}
		return fmt.Errorf("error updating status of record %s: %w", recordID, err)
	}
	return nil
}

type RecordAlreadyExistsError struct {
	Existing           *Record
	UnmarshallingError error
}

func (e *RecordAlreadyExistsError) Error() string {
	if e.UnmarshallingError == nil {
		return fmt.Sprintf("record with ID %s already exists", e.Existing.ID)
	}
	return fmt.Sprintf("record with ID already exists; there was an error when unmarshalling existing Record: %v", e.UnmarshallingError)
}

type RecordDoesNotExistsError struct {
	RecordID string
}

func (e *RecordDoesNotExistsError) Error() string {
	return fmt.Sprintf("record with ID %s already exists", e.RecordID)
}

func itemKeyFromRecordID(recordID string) map[string]types.AttributeValue {
	return map[string]types.AttributeValue{KeyAttrName: dydbutils.StringAttributeValue(recordID)}
}
