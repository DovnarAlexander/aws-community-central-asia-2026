// Package work is the SQS side: the api enqueues, the worker consumes, and
// KEDA scales on the depth between them.
package work

import (
	"context"
	"fmt"
	"strconv"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
)

type Queue struct {
	client *sqs.Client
	url    string
}

func Open(ctx context.Context, queueURL string) (*Queue, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("aws config: %w", err)
	}
	return &Queue{client: sqs.NewFromConfig(cfg), url: queueURL}, nil
}

// Enqueue pushes n messages in batches of ten, which is the SQS maximum. This
// is how the demo creates queue depth: one call from the load generator turns
// into work for KEDA to react to.
func (q *Queue) Enqueue(ctx context.Context, n int) (int, error) {
	sent := 0

	for sent < n {
		batch := min(10, n-sent)
		entries := make([]types.SendMessageBatchRequestEntry, batch)

		for i := range batch {
			id := strconv.Itoa(sent + i)
			entries[i] = types.SendMessageBatchRequestEntry{
				Id:          aws.String(id),
				MessageBody: aws.String(`{"job":` + id + `}`),
			}
		}

		out, err := q.client.SendMessageBatch(ctx, &sqs.SendMessageBatchInput{
			QueueUrl: aws.String(q.url),
			Entries:  entries,
		})
		if err != nil {
			return sent, err
		}
		sent += len(out.Successful)

		// A partial batch failure that we ignored would look like a queue that
		// drains faster than it should, which is exactly the number the demo
		// asks the audience to trust.
		if len(out.Failed) > 0 {
			return sent, fmt.Errorf("%d of %d messages rejected: %s",
				len(out.Failed), batch, aws.ToString(out.Failed[0].Message))
		}
	}
	return sent, nil
}

// Receive long-polls. Without long polling every idle worker spins on empty
// receives, which burns CPU and fills the panel the audience is reading with
// noise.
func (q *Queue) Receive(ctx context.Context, max int32) ([]types.Message, error) {
	out, err := q.client.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
		QueueUrl:            aws.String(q.url),
		MaxNumberOfMessages: max,
		WaitTimeSeconds:     20,
	})
	if err != nil {
		return nil, err
	}
	return out.Messages, nil
}

func (q *Queue) Delete(ctx context.Context, receipt *string) error {
	_, err := q.client.DeleteMessage(ctx, &sqs.DeleteMessageInput{
		QueueUrl:      aws.String(q.url),
		ReceiptHandle: receipt,
	})
	return err
}

// Depth is what KEDA scales on and what the stage panel displays. Visible plus
// in-flight, because a message being processed is still work outstanding.
func (q *Queue) Depth(ctx context.Context) (visible, inFlight int, err error) {
	out, err := q.client.GetQueueAttributes(ctx, &sqs.GetQueueAttributesInput{
		QueueUrl: aws.String(q.url),
		AttributeNames: []types.QueueAttributeName{
			types.QueueAttributeNameApproximateNumberOfMessages,
			types.QueueAttributeNameApproximateNumberOfMessagesNotVisible,
		},
	})
	if err != nil {
		return 0, 0, err
	}

	visible, _ = strconv.Atoi(out.Attributes[string(types.QueueAttributeNameApproximateNumberOfMessages)])
	inFlight, _ = strconv.Atoi(out.Attributes[string(types.QueueAttributeNameApproximateNumberOfMessagesNotVisible)])
	return visible, inFlight, nil
}
