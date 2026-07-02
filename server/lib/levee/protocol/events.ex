defmodule Levee.Protocol.Events do
  @moduledoc """
  Fluid protocol event names provided by dewdrop.
  """

  @events :levee_protocol_deps

  @compile {:no_warn_undefined, [:levee_protocol_deps]}

  def connect_document, do: @events.connect_document()
  def connect_document_success, do: @events.connect_document_success()
  def connect_document_error, do: @events.connect_document_error()
  def submit_op, do: @events.submit_op()
  def submit_signal, do: @events.submit_signal()
  def op, do: @events.op()
  def signal, do: @events.signal()
  def nack, do: @events.nack()
  def submit_summary, do: @events.submit_summary()
  def summary_ack, do: @events.summary_ack()
  def summary_nack, do: @events.summary_nack()
end
