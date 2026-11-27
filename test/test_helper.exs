# Created here so the table outlives individual test processes.
QPBX.FakeHelper.reset()
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(QPBX.Repo, :manual)
