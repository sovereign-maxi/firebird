ExUnit.start()

# Start Faker
{:ok, _apps} = Application.ensure_all_started(:faker)
