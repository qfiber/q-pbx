defmodule QPBX.Web.Api.ExtensionController do
  @moduledoc """
  Extensions and their devices (tenant keys), through the same Core functions the portal
  uses. A device's SIP password is returned once, when it is added or reset.
  """
  use QPBX.Web, :api_controller
  alias QPBX.{Core, Telephony}
  alias QPBX.Core.{Device, Extension}

  @ext Schemas.of(Extension, "Extension")
  @input Schemas.input(Extension, "ExtensionInput", ~w(number name))
  @device Schemas.of(Device, "Device")
  @with_password %{type: "object", properties: %{data: @device, sip_password: %{type: "string"}}}

  def operation(:index),
    do:
      op("Extensions", "List extensions", "read", :tenant,
        params: Page.params(),
        response: {:list, @ext}
      )

  def operation(:show), do: op("Extensions", "Get an extension", "read", :tenant, response: @ext)

  def operation(:create),
    do:
      op("Extensions", "Create an extension", "write", :tenant,
        body: @input,
        status: 201,
        response: @ext
      )

  def operation(:update),
    do:
      op("Extensions", "Change an extension (numbers in E.164)", "write", :tenant,
        body: Schemas.input(Extension, "ExtensionChange"),
        response: @ext
      )

  def operation(:delete),
    do:
      op("Extensions", "Delete an extension with its devices and voicemail", "write", :tenant,
        response: nil
      )

  def operation(:add_device),
    do:
      op(
        "Extensions",
        "Add a device; the SIP password is in this response only",
        "write",
        :tenant,
        body: Schemas.input(Device, "DeviceInput", ["kind"]),
        status: 201,
        response: {:raw, @with_password}
      )

  def operation(:delete_device),
    do:
      op("Extensions", "Remove a device (its SIP login stops at once)", "write", :tenant,
        response: nil
      )

  def operation(:reset_device),
    do:
      op("Extensions", "New SIP password for a device, in this response only", "write", :tenant,
        response: {:raw, @with_password}
      )

  def index(conn, params), do: paged(conn, Core.list_extensions(scope(conn)), params)

  # Another tenant's id is simply not found (tenant filter and row-level security).
  def show(conn, %{"id" => id}), do: data(conn, Core.get_extension!(scope(conn), id))

  def create(conn, params) do
    with {:ok, ext} <- Core.create_extension(scope(conn), params, actor(conn)),
         do: data(conn, Core.get_extension!(scope(conn), ext.id), 201)
  end

  def update(conn, %{"id" => id} = params) do
    ext = Core.get_extension!(scope(conn), id)

    with {:ok, _} <-
           Core.update_extension(scope(conn), ext, Map.drop(params, ["id"]), actor(conn)),
         do: data(conn, Core.get_extension!(scope(conn), id))
  end

  def delete(conn, %{"id" => id}) do
    ext = Core.get_extension!(scope(conn), id)
    # Its voicemail first: messages and greetings are files the database cascade cannot remove.
    :ok = Telephony.delete_mailbox(scope(conn), ext.id, actor(conn))
    reply(conn, Core.delete_extension(scope(conn), ext, actor(conn)), 204)
  end

  def add_device(conn, %{"extension_id" => id} = params) do
    ext = Core.get_extension!(scope(conn), id)

    with {:ok, device, password} <-
           Core.add_device(scope(conn), ext, Map.drop(params, ["extension_id"]), actor(conn)),
         do: with_password(conn, device, password, 201)
  end

  def delete_device(conn, %{"id" => id}),
    do: reply(conn, Core.delete_device(scope(conn), id, actor(conn)), 204)

  def reset_device(conn, %{"id" => id}) do
    with {:ok, device, password} <- Core.reset_device_password(scope(conn), id, actor(conn)),
         do: with_password(conn, device, password, 200)
  end

  defp with_password(conn, device, password, status) do
    device =
      Enum.find(
        Core.get_extension!(scope(conn), device.extension_id).devices,
        &(&1.id == device.id)
      )

    conn |> put_status(status) |> json(%{data: Schemas.render(device), sip_password: password})
  end

  defp scope(conn), do: conn.assigns.current_scope
  defp actor(conn), do: conn.assigns.api_key
end
