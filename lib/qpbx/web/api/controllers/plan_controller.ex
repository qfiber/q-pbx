defmodule QPBX.Web.Api.PlanController do
  @moduledoc "Plans (platform keys): limits, destination classes, features."
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Core.Plan

  @plan Schemas.of(Plan, "Plan")

  def operation(:index),
    do:
      op("Plans", "List plans", "read", :platform,
        params: Page.params(),
        response: {:list, @plan}
      )

  def operation(:show), do: op("Plans", "Get a plan", "read", :platform, response: @plan)

  def operation(:create),
    do:
      op("Plans", "Create a plan", "write", :platform,
        body: Schemas.input(Plan, "PlanInput", ["name"]),
        status: 201,
        response: @plan
      )

  def operation(:update),
    do:
      op("Plans", "Change a plan (its tenants get the new limits at once)", "write", :platform,
        body: Schemas.input(Plan, "PlanInput"),
        response: @plan
      )

  def index(conn, params), do: paged(conn, Core.list_plans(), params)
  def show(conn, %{"id" => id}), do: data(conn, Core.get_plan!(id))
  def create(conn, params), do: reply(conn, Core.create_plan(params, conn.assigns.api_key), 201)

  def update(conn, %{"id" => id} = p),
    do: reply(conn, Core.update_plan(Core.get_plan!(id), p, conn.assigns.api_key))
end
