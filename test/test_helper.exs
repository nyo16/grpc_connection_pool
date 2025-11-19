# Start the GRPC Client Supervisor as required by grpc >= 0.11.0
{:ok, _pid} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

ExUnit.start()
