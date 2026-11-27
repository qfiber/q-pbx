defmodule QPBX.Telephony do
  @moduledoc """
  Public API of the telephony area: call control. FreeSWITCH asks for a dialplan
  (`dialplan_xml/1`, served by the web area at `/internal/freeswitch/dialplan`) and is told to
  park every call; one process per call then drives it over the event socket. See
  `lib/qpbx/telephony/README.md`.
  """
  use Boundary,
    deps: [QPBX.Repo, QPBX.Core, QPBX.Events],
    exports: [Router, Dialplan, Cache, Calls, Usage, Fraud, Admission]

  alias QPBX.Telephony.{Calls, Dialplan}
  alias QPBX.Telephony.ESL.Connection

  @doc "The dialplan XML for a FreeSWITCH request (park under call control)."
  defdelegate dialplan_xml(params), to: Dialplan, as: :xml

  @doc "Whether the event socket to FreeSWITCH is up (health check)."
  def connected?, do: Process.whereis(Connection) != nil and Connection.connected?()

  ## Fraud protection (platform admins)

  alias QPBX.Telephony.Fraud
  defdelegate fraud_settings(), to: Fraud, as: :settings
  defdelegate change_fraud_settings(settings, attrs \\ %{}), to: Fraud, as: :change_settings
  defdelegate update_fraud_settings(attrs, actor), to: Fraud, as: :update_settings
  defdelegate list_fraud_blocks(), to: Fraud, as: :list_blocks
  defdelegate lift_fraud_block(id, actor), to: Fraud, as: :lift

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
        # Call admission's concurrency counts (joined by call processes).
        {Registry, keys: :duplicate, name: QPBX.Telephony.Active},
        QPBX.Telephony.Fraud,
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
