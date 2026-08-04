# Exclude special-purpose tags from bare `mix test`. Scenario tests
# spin up supervised trees + mock clients + WAL replay; run them
# explicitly:
#   mix test --only scenario
ExUnit.configure(exclude: [:scenario, :integration, :load, :property])

ExUnit.start()

# Start Faker
{:ok, _apps} = Application.ensure_all_started(:faker)
