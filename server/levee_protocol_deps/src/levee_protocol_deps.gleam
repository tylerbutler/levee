import dewdrop/events
import spillway

pub fn protocol_loaded() -> Bool {
  let _ = spillway.new_sequence_state()
  events.connect_document == "connect_document"
}

pub fn connect_document() -> String {
  events.connect_document
}

pub fn connect_document_success() -> String {
  events.connect_document_success
}

pub fn connect_document_error() -> String {
  events.connect_document_error
}

pub fn submit_op() -> String {
  events.submit_op
}

pub fn submit_signal() -> String {
  events.submit_signal
}

pub fn op() -> String {
  events.op
}

pub fn signal() -> String {
  events.signal
}

pub fn nack() -> String {
  events.nack
}

pub fn submit_summary() -> String {
  events.submit_summary
}

pub fn summary_ack() -> String {
  events.summary_ack
}

pub fn summary_nack() -> String {
  events.summary_nack
}
