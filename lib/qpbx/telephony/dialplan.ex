defmodule QPBX.Telephony.Dialplan do
  @moduledoc """
  The answer to FreeSWITCH's dialplan request (`mod_xml_curl`): mark the call as ours and
  park it, so its call process takes over. A failed or finished bridge must hand control back
  (FreeSWITCH would otherwise hang up the caller after a failed bridge, so no failover could
  follow): `continue_on_fail=true`, `hangup_after_bridge=false`. A park timeout ends the call with a temporary
  failure (a carrier then fails over) if no call process picks it up.
  """

  @park_timeout 30

  @echo "qpbx-echo"

  @doc "The loopback destination of the echo test."
  def echo_destination, do: @echo

  @doc """
  The dialplan for a request. Our own loopback channel to the echo destination gets the echo
  test (a phone dialling that name arrives through sofia and is parked like any call); every
  other call is parked under call control.
  """
  def xml(%{"Caller-Destination-Number" => @echo, "Channel-Name" => "loopback/" <> _}),
    do: echo_xml()

  def xml(_params), do: park_xml()

  # A tone prompt of about 5 s (so a far end hears the service at once), then the echo.
  defp echo_xml do
    document("""
    <action application="answer"/>
    <action application="sleep" data="300"/>
    <action application="playback" data="tone_stream://%(400,200,440,660);loops=10"/>
    <action application="echo"/>
    """)
  end

  defp park_xml do
    document("""
    <action application="set" data="qpbx_call=true"/>
    <action application="set" data="continue_on_fail=true"/>
    <action application="set" data="hangup_after_bridge=false"/>
    <action application="set" data="park_timeout=#{@park_timeout}:NORMAL_TEMPORARY_FAILURE"/>
    <action application="park"/>
    """)
  end

  defp document(actions) do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <document type="freeswitch/xml">
      <section name="dialplan">
        <context name="public">
          <extension name="qpbx">
            <condition field="destination_number" expression="^.*$">
    #{actions}        </condition>
          </extension>
        </context>
      </section>
    </document>
    """
  end
end
