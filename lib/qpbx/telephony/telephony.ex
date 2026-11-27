defmodule QPBX.Telephony do
  @moduledoc """
  Public API of the telephony area: call control. FreeSWITCH asks for a dialplan
  (`dialplan_xml/1`, served by the web area at `/internal/freeswitch/dialplan`) and is told to
  park every call; one process per call then drives it over the event socket. See
  `lib/qpbx/telephony/README.md`.
  """
  use Boundary, deps: [QPBX.Core, QPBX.Events], exports: [Router, Dialplan, Cache, Calls]

  alias QPBX.Telephony.{Calls, Dialplan}
  alias QPBX.Telephony.ESL.Connection

  @doc "The dialplan XML for a FreeSWITCH request (park under call control)."
  defdelegate dialplan_xml(params), to: Dialplan, as: :xml

  @doc "Whether the event socket to FreeSWITCH is up (health check)."
  def connected?, do: Process.whereis(Connection) != nil and Connection.connected?()

  @doc "The password FreeSWITCH must send with dialplan requests."
  def curl_password, do: Application.get_env(:qpbx, __MODULE__, [])[:curl_password]

  @doc "Calls in progress."
  defdelegate active_calls(), to: Calls, as: :count

  @doc "The supervision tree of call control (started by the application)."
  def child_spec(_) do
    # The event socket only where FreeSWITCH runs (config `esl: true`, production).
    esl? = Application.get_env(:qpbx, __MODULE__, [])[:esl] == true

    children =
      [
        {Registry, keys: :unique, name: QPBX.Telephony.Registry},
        {Registry, keys: :duplicate, name: QPBX.Telephony.InUse},
        {DynamicSupervisor, name: QPBX.Telephony.CallSupervisor, strategy: :one_for_one},
        QPBX.Telephony.Cache
      ] ++ if(esl?, do: [Connection], else: [])

    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_one, name: QPBX.Telephony.Supervisor]]}
    }
  end
end
