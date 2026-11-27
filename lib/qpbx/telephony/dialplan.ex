defmodule QPBX.Telephony.Dialplan do
  @moduledoc """
  The answer to FreeSWITCH's dialplan request (`mod_xml_curl`): mark the call as ours and
  park it, so its call process takes over. A failed or finished bridge must hand control back
  (FreeSWITCH would otherwise hang up the caller after a failed bridge, so no failover could
  follow): `continue_on_fail=true`, `hangup_after_bridge=false`. A park timeout ends the call with a temporary
  failure (a carrier then fails over) if no call process picks it up.
  """

  @park_timeout 30

  def xml(_params) do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <document type="freeswitch/xml">
      <section name="dialplan">
        <context name="public">
          <extension name="qpbx">
            <condition field="destination_number" expression="^.*$">
              <action application="set" data="qpbx_call=true"/>
              <action application="set" data="continue_on_fail=true"/>
              <action application="set" data="hangup_after_bridge=false"/>
              <action application="set" data="park_timeout=#{@park_timeout}:NORMAL_TEMPORARY_FAILURE"/>
              <action application="park"/>
            </condition>
          </extension>
        </context>
      </section>
    </document>
    """
  end
end
