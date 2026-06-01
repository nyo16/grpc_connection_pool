# Start the GRPC Client Supervisor as required by grpc >= 0.11.0
{:ok, _pid} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

# `:emulator`-tagged tests are opt-in integration tests that require a live
# Google Pub/Sub emulator on localhost:8085. Exclude them by default so a plain
# `mix test` is green without external services (CI also passes --exclude
# emulator). Run them with: `mix test --include emulator` (emulator up).
ExUnit.start(exclude: [:emulator])
