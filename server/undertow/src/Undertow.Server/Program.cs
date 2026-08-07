// Phase 3 fills this in: env config, RestLess middleware, authorize_* helpers,
// full REST router. Until then a /health stub proves the host wiring.
var builder = WebApplication.CreateSlimBuilder(args);
var app = builder.Build();

app.MapGet("/health", () => Results.Text("{\"status\":\"ok\"}", "application/json"));

app.Run();

public partial class Program;
