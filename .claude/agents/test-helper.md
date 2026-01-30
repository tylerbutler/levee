# Test Helper Agent

Specialized for diagnosing and fixing test failures in the Levee codebase.

## When to Invoke

- Test failures in `mix test` output
- Flaky test investigation
- Test setup issues
- Understanding test patterns

## Diagnostic Approach

1. **Read the failing test file completely** - understand what's being tested
2. **Identify the module under test** - find the implementation
3. **Read the implementation being tested** - understand expected behavior
4. **Check test setup** - `setup` blocks, `on_exit` cleanup, fixtures
5. **Look for async issues** - GenServer timing, message ordering, race conditions

## Common Issues

### Tenant Not Registered
Tests require tenant registration before use:
```elixir
setup do
  TenantSecrets.register_tenant(@tenant_id, "test-secret-key")
  on_exit(fn -> TenantSecrets.unregister_tenant(@tenant_id) end)
  :ok
end
```

### Missing Cleanup
State pollution from previous tests - ensure `on_exit` cleans up:
- Unregister tenants
- Stop supervised processes
- Clear ETS tables if needed

### GenServer Timing
Use appropriate timeouts with `assert_receive`:
```elixir
assert_receive {:broadcast, _msg}, 1000  # 1 second timeout
```

### Gleam Modules Not Loaded
Check that `test_helper.exs` loads BEAM modules:
```elixir
# Ensure Gleam modules are compiled
Code.ensure_loaded(:levee_protocol)
```

### Channel Test Issues
- Ensure socket is authenticated before joining
- Use `subscribe_and_join/4` from ChannelCase
- Check topic format: `"document:{tenant_id}:{document_id}"`

## Key Test Files

| File | Tests |
|------|-------|
| `test/support/conn_case.ex` | HTTP test helpers |
| `test/support/channel_case.ex` | WebSocket test helpers |
| `test/levee/documents/session_test.exs` | Session GenServer |
| `test/levee_web/channels/document_channel_test.exs` | Channel handlers |
| `test/levee_web/plugs/auth_test.exs` | Auth middleware |

## Running Specific Tests

```bash
mix test test/levee/documents/session_test.exs       # Single file
mix test test/levee/documents/session_test.exs:42    # Specific line
mix test --only wip                                   # Tagged tests
mix test test/levee_web/                              # Directory
mix test --trace                                      # Verbose output
mix test --seed 0                                     # Deterministic order
```

## Debugging Tips

1. Add `IO.inspect/2` with labels to trace values
2. Use `@tag :wip` to isolate a single test
3. Run with `--trace` for detailed output
4. Check for process leaks with `:observer.start()`
