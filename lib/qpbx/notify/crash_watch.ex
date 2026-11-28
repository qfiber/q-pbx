defmodule QPBX.Notify.CrashWatch do
  @moduledoc """
  A logger handler: every crash report (a process that died with an error) is counted by the
  kind of process (its registered name, else the module it started in) in
  `QPBX.Notify.Sources`, which raises a crash-loop alert at 3 within 5 minutes.
  """
  @id :qpbx_crash_watch

  @doc "Adds the handler (once)."
  def install do
    case :logger.add_handler(@id, __MODULE__, %{level: :error}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
    end
  end

  @doc false
  def log(%{meta: meta} = event, _config) do
    if crash?(event), do: QPBX.Notify.Sources.crashed(kind(meta))
    :ok
  end

  defp crash?(%{meta: %{crash_reason: _}}), do: true
  defp crash?(%{msg: {:report, %{label: {:proc_lib, :crash}}}}), do: true
  defp crash?(_), do: false

  defp kind(%{registered_name: name}) when is_atom(name) and name != [], do: inspect(name)
  defp kind(%{initial_call: {m, _, _}}), do: inspect(m)
  defp kind(%{mfa: {m, _, _}}), do: inspect(m)
  defp kind(_), do: "a process"
end
