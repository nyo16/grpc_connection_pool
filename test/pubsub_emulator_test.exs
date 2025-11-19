defmodule GrpcConnectionPool.PubSubEmulatorTest do
  @moduledoc """
  Integration test with Google Pub/Sub emulator to verify the library works with real gRPC services.

  To run this test, start the Pub/Sub emulator:

      docker run --rm -p 8085:8085 google/cloud-sdk:emulators-pubsub \
        /google-cloud-sdk/bin/gcloud beta emulators pubsub start \
        --host-port=0.0.0.0:8085 --project=test-project

  Or use the docker-compose.yml file if available.
  """
  use ExUnit.Case

  alias GrpcConnectionPool.{Config, Pool}

  @moduletag :emulator

  describe "Pub/Sub emulator integration" do
    setup do
      # Configuration for Pub/Sub emulator
      {:ok, config} =
        Config.local(
          host: "localhost",
          port: 8085,
          pool_size: 2
        )

      pool_name = :"pubsub_test_pool_#{:rand.uniform(10000)}"

      # Start the pool
      case Pool.start_link(config, name: pool_name) do
        {:ok, _pid} ->
          on_exit(fn -> Pool.stop(pool_name) end)
          %{pool_name: pool_name}

        {:error, reason} ->
          # Skip test if emulator is not available
          {:skip, "Pub/Sub emulator not available: #{inspect(reason)}"}
      end
    end

    @tag timeout: 10_000
    test "creates and lists topics", %{pool_name: pool_name} do
      topic_name = "test-topic-#{:rand.uniform(10000)}"
      topic_path = "projects/test-project/topics/#{topic_name}"

      # Create a topic
      create_operation = fn channel ->
        request = %Google.Pubsub.V1.Topic{name: topic_path}
        Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
      end

      result = Pool.execute(create_operation, pool: pool_name)
      assert match?({:ok, {:ok, %Google.Pubsub.V1.Topic{name: ^topic_path}}}, result)

      # List topics
      list_operation = fn channel ->
        request = %Google.Pubsub.V1.ListTopicsRequest{
          project: "projects/test-project",
          page_size: 10
        }

        Google.Pubsub.V1.Publisher.Stub.list_topics(channel, request)
      end

      {:ok, {:ok, response}} = Pool.execute(list_operation, pool: pool_name)
      assert Enum.any?(response.topics, fn topic -> topic.name == topic_path end)

      # Clean up - delete the topic
      delete_operation = fn channel ->
        request = %Google.Pubsub.V1.DeleteTopicRequest{topic: topic_path}
        Google.Pubsub.V1.Publisher.Stub.delete_topic(channel, request)
      end

      assert {:ok, {:ok, %Google.Protobuf.Empty{}}} =
               Pool.execute(delete_operation, pool: pool_name)
    end

    @tag timeout: 10_000
    test "publishes and pulls messages", %{pool_name: pool_name} do
      topic_name = "test-topic-#{:rand.uniform(10000)}"
      topic_path = "projects/test-project/topics/#{topic_name}"
      subscription_name = "test-subscription-#{:rand.uniform(10000)}"
      subscription_path = "projects/test-project/subscriptions/#{subscription_name}"

      # Create topic
      create_topic = fn channel ->
        request = %Google.Pubsub.V1.Topic{name: topic_path}
        Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
      end

      {:ok, {:ok, _}} = Pool.execute(create_topic, pool: pool_name)

      # Create subscription
      create_subscription = fn channel ->
        request = %Google.Pubsub.V1.Subscription{
          name: subscription_path,
          topic: topic_path,
          ack_deadline_seconds: 60
        }

        Google.Pubsub.V1.Subscriber.Stub.create_subscription(channel, request)
      end

      {:ok, {:ok, _}} = Pool.execute(create_subscription, pool: pool_name)

      # Publish message
      message_data = "Hello from gRPC connection pool!"

      publish_operation = fn channel ->
        message = %Google.Pubsub.V1.PubsubMessage{
          data: message_data,
          attributes: %{"source" => "grpc_connection_pool_test"}
        }

        request = %Google.Pubsub.V1.PublishRequest{
          topic: topic_path,
          messages: [message]
        }

        Google.Pubsub.V1.Publisher.Stub.publish(channel, request)
      end

      {:ok, {:ok, publish_response}} = Pool.execute(publish_operation, pool: pool_name)
      assert length(publish_response.message_ids) == 1

      # Pull message
      pull_operation = fn channel ->
        request = %Google.Pubsub.V1.PullRequest{
          subscription: subscription_path,
          max_messages: 1
        }

        Google.Pubsub.V1.Subscriber.Stub.pull(channel, request)
      end

      # Sometimes need to retry pulling as message delivery is async
      {:ok, pull_response} =
        retry_until(
          fn ->
            case Pool.execute(pull_operation, pool: pool_name) do
              {:ok, {:ok, %{received_messages: []}}} -> :retry
              {:ok, {:ok, response}} -> {:ok, response}
              error -> error
            end
          end, max_attempts: 5, delay: 100)

      assert length(pull_response.received_messages) == 1
      received_message = hd(pull_response.received_messages)
      assert received_message.message.data == message_data
      assert received_message.message.attributes["source"] == "grpc_connection_pool_test"

      # Acknowledge message
      ack_operation = fn channel ->
        request = %Google.Pubsub.V1.AcknowledgeRequest{
          subscription: subscription_path,
          ack_ids: [received_message.ack_id]
        }

        Google.Pubsub.V1.Subscriber.Stub.acknowledge(channel, request)
      end

      assert {:ok, {:ok, %Google.Protobuf.Empty{}}} = Pool.execute(ack_operation, pool: pool_name)

      # Cleanup
      delete_sub = fn channel ->
        request = %Google.Pubsub.V1.DeleteSubscriptionRequest{subscription: subscription_path}
        Google.Pubsub.V1.Subscriber.Stub.delete_subscription(channel, request)
      end

      Pool.execute(delete_sub, pool: pool_name)

      delete_topic = fn channel ->
        request = %Google.Pubsub.V1.DeleteTopicRequest{topic: topic_path}
        Google.Pubsub.V1.Publisher.Stub.delete_topic(channel, request)
      end

      Pool.execute(delete_topic, pool: pool_name)
    end

    test "handles connection pooling correctly", %{pool_name: pool_name} do
      # Execute multiple concurrent operations to test pooling
      tasks =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            operation = fn channel ->
              request = %Google.Pubsub.V1.ListTopicsRequest{
                project: "projects/test-project"
              }

              result = Google.Pubsub.V1.Publisher.Stub.list_topics(channel, request)
              {i, result}
            end

            Pool.execute(operation, pool: pool_name)
          end)
        end)

      results = Task.await_many(tasks, 10_000)

      # All operations should succeed
      assert Enum.all?(results, fn
               {:ok, {_i, {:ok, %Google.Pubsub.V1.ListTopicsResponse{}}}} -> true
               _ -> false
             end)

      # Should have results from all 10 tasks
      assert length(results) == 10
    end
  end

  # Helper function for retrying operations
  defp retry_until(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    delay = Keyword.get(opts, :delay, 1000)

    retry_until(fun, max_attempts, delay)
  end

  defp retry_until(fun, attempts_left, delay) when attempts_left > 0 do
    case fun.() do
      :retry when attempts_left > 1 ->
        :timer.sleep(delay)
        retry_until(fun, attempts_left - 1, delay)

      :retry ->
        {:error, :max_retries_exceeded}

      result ->
        result
    end
  end

  defp retry_until(_, 0, _), do: {:error, :max_retries_exceeded}
end
