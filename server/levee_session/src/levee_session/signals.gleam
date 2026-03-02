//// Signal relay — v1/v2 format support with targeting.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode

@external(erlang, "gleam_stdlib", "identity")
fn coerce(val: a) -> b

import gleam/list
import gleam/option.{type Option, None, Some}
import levee_protocol/session_logic
import levee_session/ops
import levee_session/state.{type ClientInfo}

/// Broadcast signals from a client to appropriate recipients.
pub fn broadcast_signals(
  sender_client_id: String,
  batches: Dynamic,
  clients: Dict(String, ClientInfo),
  _document_id: String,
) -> Nil {
  let signals = decode_signal_list(batches)
  list.each(signals, fn(signal) {
    broadcast_single_signal(sender_client_id, signal, clients)
  })
}

fn broadcast_single_signal(
  sender_client_id: String,
  signal: Dynamic,
  clients: Dict(String, ClientInfo),
) -> Nil {
  let all_client_ids = dict.keys(clients)

  // Build signal message
  let message = build_signal_message(sender_client_id, signal)

  // Determine recipients via Gleam protocol
  let targeted = wrap_option_list(signal, "targetedClients")
  let ignored = wrap_option_list(signal, "ignoredClients")
  let single_target = wrap_option_string(signal, "targetClientId")

  let recipients =
    session_logic.determine_signal_recipients(
      sender_client_id,
      targeted,
      ignored,
      single_target,
      all_client_ids,
    )

  // Send to each recipient
  list.each(recipients, fn(client_id) {
    case dict.get(clients, client_id) {
      Ok(info) -> ops.send_signal(info.pid, message)
      Error(_) -> Nil
    }
  })
}

fn build_signal_message(sender_client_id: String, signal: Dynamic) -> Dynamic {
  let base =
    dict.from_list([
      #("clientId", coerce(sender_client_id)),
      #("content", coerce(ops.get_dynamic_field(signal, "content"))),
      #("type", coerce(ops.get_string_field(signal, "type", ""))),
    ])

  let with_optional =
    base
    |> put_if_present(signal, "clientConnectionNumber")
    |> put_if_present(signal, "referenceSequenceNumber")
    |> put_if_present(signal, "targetClientId")

  coerce(with_optional)
}

fn put_if_present(
  map: Dict(String, Dynamic),
  signal: Dynamic,
  key: String,
) -> Dict(String, Dynamic) {
  let value = ops.get_dynamic_field(signal, key)
  case dynamic.classify(value) {
    "Nil" -> map
    "Atom" -> map
    _ -> dict.insert(map, key, value)
  }
}

fn wrap_option_list(value: Dynamic, key: String) -> Option(List(String)) {
  let decoder = {
    use v <- decode.optional_field(
      key,
      None,
      decode.optional(decode.list(decode.string)),
    )
    decode.success(v)
  }
  case decode.run(value, decoder) {
    Ok(Some(lst)) ->
      case lst {
        [] -> None
        _ -> Some(lst)
      }
    _ -> None
  }
}

fn wrap_option_string(value: Dynamic, key: String) -> Option(String) {
  let decoder = {
    use v <- decode.optional_field(key, None, decode.optional(decode.string))
    decode.success(v)
  }
  case decode.run(value, decoder) {
    Ok(Some(s)) ->
      case s {
        "" -> None
        _ -> Some(s)
      }
    _ -> None
  }
}

fn decode_signal_list(batches: Dynamic) -> List(Dynamic) {
  case decode.run(batches, decode.list(decode.dynamic)) {
    Ok(signals) -> signals
    Error(_) -> []
  }
}
