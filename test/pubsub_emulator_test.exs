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
          # Wait for at least one connection to be ready
          case wait_for_connection(pool_name, 5000) do
            :ok ->
              on_exit(fn ->
                try do
                  Pool.stop(pool_name)
                catch
                  :exit, _reason -> :ok
                end
              end)
              %{pool_name: pool_name}
            {:error, :timeout} ->
              try do
                Pool.stop(pool_name)
              catch
                :exit, _reason -> :ok
              end
              {:skip, "Pub/Sub emulator not available: timeout waiting for connection"}
          end

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
      assert {:ok, channel} = Pool.get_channel(pool_name)
      request = %Google.Pubsub.V1.Topic{name: topic_path}
      assert {:ok, %Google.Pubsub.V1.Topic{name: ^topic_path}} =
        Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)

      # List topics
      assert {:ok, channel} = Pool.get_channel(pool_name)
      request = %Google.Pubsub.V1.ListTopicsRequest{
        project: "projects/test-project",
        page_size: 10
      }
      assert {:ok, response} = Google.Pubsub.V1.Publisher.Stub.list_topics(channel, request)
      assert Enum.any?(response.topics, fn topic -> topic.name == topic_path end)

      # Clean up - delete the topic
      assert {:ok, channel} = Pool.get_channel(pool_name)
      request = %Google.Pubsub.V1.DeleteTopicRequest{topic: topic_path}
      assert {:ok, %Google.Protobuf.Empty{}} =
        Google.Pubsub.V1.Publisher.Stub.delete_topic(channel, request)
    end

    @tag timeout: 10_000
    test "publishes and pulls messages", %{pool_name: pool_name} do
      topic_name = "test-topic-#{:rand.uniform(10000)}"
      topic_path = "projects/test-project/topics/#{topic_name}"
      subscription_name = "test-subscription-#{:rand.uniform(10000)}"
      subscription_path = "projects/test-project/subscriptions/#{subscription_name}"

      # Create topic
      {:ok, channel} = Pool.get_channel(pool_name)
      request = %Google.Pubsub.V1.Topic{name: topic_path}
      {:ok, _} = Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)

      # Create subscription
      {:ok, channel} = Pool.get_channel(pool_name)
      request = %Google.Pubsub.V1.Subscription{
        name: subscription_path,
        topic: topic_path,
        ack_deadline_seconds: 60
      }
      {:ok, _} = Google.Pubsub.V1.Subscriber.Stub.create_subscription(channel, request)

      # Publish message
      message_data = "Hello from gRPC connection pool!"
      {:ok, channel} = Pool.get_channel(pool_name)
      message = %Google.Pubsub.V1.PubsubMessage{
        data: message_data,
        attributes: %{"source" => "grpc_connection_pool_test"}
      }
      request = %Google.Pubsub.V1.PublishRequest{
        topic: topic_path,
        messages: [message]
      }
      {:ok, publish_response} = Google.Pubsub.V1.Publisher.Stub.publish(channel, request)
      assert length(publish_response.message_ids) == 1

      # Pull message - retry as message delivery is async
      {:ok, pull_response} =
        retry_until(
          fn ->
            {:ok, channel} = Pool.get_channel(pool_name)
            request = %Google.Pubsub.V1.PullRequest{
              subscription: subscription_path,
              max_messages: 1
            }
            case Google.Pubsub.V1.Subscriber.Stub.pull(channel, request) do
              {:ok, %{received_messages: []}} -> :retry
              {:ok, response} -> {:ok, response}
              error -> error
            end
          end, max_attempts: 5, delay: 100)

      assert length(pull_response.received_messages) == 1
      received_message = hd(pull_response.received_messages)
      assert received_message.message.data == message_data
      assert received_message.message.attributes["source"] == "grpc_connection_pool_test"

      # Acknowledge message
      {:ok, channel} = Pool.get_channel(pool_name)
      request = %Google.Pubsub.V1.AcknowledgeRequest{
        subscription: subscription_path,
        ack_ids: [received_message.ack_id]
      }
      assert {:ok, %Google.Protobuf.Empty{}} =
        Google.Pubsub.V1.Subscriber.Stub.acknowledge(channel, request)

      # Cleanup
      {:ok, channel} = Pool.get_channel(pool_name)
      request = %Google.Pubsub.V1.DeleteSubscriptionRequest{subscription: subscription_path}
      Google.Pubsub.V1.Subscriber.Stub.delete_subscription(channel, request)

      {:ok, channel} = Pool.get_channel(pool_name)
      request = %Google.Pubsub.V1.DeleteTopicRequest{topic: topic_path}
      Google.Pubsub.V1.Publisher.Stub.delete_topic(channel, request)
    end

    test "handles connection pooling correctly", %{pool_name: pool_name} do
      # Execute multiple concurrent operations to test pooling
      tasks =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            {:ok, channel} = Pool.get_channel(pool_name)
            request = %Google.Pubsub.V1.ListTopicsRequest{
              project: "projects/test-project"
            }
            result = Google.Pubsub.V1.Publisher.Stub.list_topics(channel, request)
            {i, result}
          end)
        end)

      results = Task.await_many(tasks, 10_000)

      # All operations should succeed
      assert Enum.all?(results, fn
               {_i, {:ok, %Google.Pubsub.V1.ListTopicsResponse{}}} -> true
               _ -> false
             end)

      # Should have results from all 10 tasks
      assert length(results) == 10
    end
  end

  # Helper function for retrying operations
  defp retry_until(fun, opts) do
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

  # Helper to wait for pool to have at least one connection
  defp wait_for_connection(pool_name, timeout) do
    start_time = System.monotonic_time(:millisecond)
    wait_for_connection_loop(pool_name, start_time, timeout)
  end

  defp wait_for_connection_loop(pool_name, start_time, timeout) do
    case Pool.get_channel(pool_name) do
      {:ok, _channel} ->
        :ok

      {:error, :not_connected} ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        if elapsed >= timeout do
          {:error, :timeout}
        else
          :timer.sleep(100)
          wait_for_connection_loop(pool_name, start_time, timeout)
        end
    end
  end
end
