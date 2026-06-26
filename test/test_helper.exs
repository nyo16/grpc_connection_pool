# grpc >= 1.0 starts GRPC.Client.Supervisor itself via GRPC.Client.Application,
# so no manual supervisor start is needed here.

# `:emulator`-tagged tests are opt-in integration tests that require a live
# Google Pub/Sub emulator on localhost:8085. Exclude them by default so a plain
# `mix test` is green without external services (CI also passes --exclude
# emulator). Run them with: `mix test --include emulator` (emulator up).
ExUnit.start(exclude: [:emulator])
