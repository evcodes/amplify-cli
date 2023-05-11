import { waitTillTableStateIsActive } from '../../../utils/dynamo-db/helpers';
import * as AWSMock from 'aws-sdk-mock';
import * as AWS from 'aws-sdk';
import { DynamoDB } from 'aws-sdk';

describe('aitTillTableStateIsActive', () => {
  const describeTableMock = jest.fn();
  beforeEach(() => {
    jest.resetAllMocks();
    jest.useFakeTimers();
    AWSMock.setSDKInstance(AWS);
  });

  afterEach(() => {
    jest.clearAllTimers();
  });

  it('should wait for table to be in active state', async () => {
    describeTableMock.mockImplementation(({ TableName }) => ({
      promise: jest.fn().mockResolvedValue({
        Table: {
          TableName,
          TableStatus: 'ACTIVE',
        },
      }),
    }));
    const dynamoDBClient = {
      describeTable: describeTableMock,
    };

    const waitTillTableStateIsActivePromise = waitTillTableStateIsActive(dynamoDBClient as unknown as DynamoDB, 'table1');
    jest.advanceTimersByTime(1000);
    await waitTillTableStateIsActivePromise
    expect(describeTableMock.mock.calls[0][0]).toEqual({ TableName: 'table1' });
  });

  it.only('should reject the promise when table does not become active for timeout period', async () => {
    describeTableMock.mockImplementation(({ TableName }) => ({
      promise: jest.fn().mockResolvedValue({
        Table: {
          TableName,
          TableStatus: 'UPDATING',
        },
      }),
    }));

    const dynamoDBClient = {
      describeTable: describeTableMock,
    };
    const waitTillTableStateIsActivePromise = waitTillTableStateIsActive(dynamoDBClient as unknown as DynamoDB, 'table1');
    jest.advanceTimersByTime(2000);
    const res = await waitTillTableStateIsActivePromise
    console.log(res);
    
    await expect(waitTillTableStateIsActivePromise).rejects.toMatchObject({ message: 'Waiting for table status to turn ACTIVE timed out' });
    expect(describeTableMock).toHaveBeenCalled();
  }, 25000);

  it('should periodically call check status', async () => {
    let callCount = 0;
    describeTableMock.mockImplementation(({ TableName }) => {
      callCount += 1;
      promise: jest.fn().mockResolvedValue({
        Table: {
          TableName,
          TableStatus: callCount === 3 ? 'ACTIVE' : 'UPDATING',
        },
      });
    });
    const dynamoDBClient = {
      describeTable: describeTableMock,
    };

    const waitTillTableStateIsActivePromise = waitTillTableStateIsActive(dynamoDBClient as unknown as DynamoDB, 'table1');
    jest.advanceTimersByTime(3000);
    await waitTillTableStateIsActivePromise;
    expect(describeTableMock).toBeCalledTimes(4);
    expect(describeTableMock.mock.calls[0][0]).toEqual({ TableName: 'table1' });
    expect(describeTableMock.mock.calls[1][0]).toEqual({ TableName: 'table1' });
    expect(describeTableMock.mock.calls[2][0]).toEqual({ TableName: 'table1' });
    expect(describeTableMock.mock.calls[3][0]).toEqual({ TableName: 'table1' });
  }, 10000);
});
