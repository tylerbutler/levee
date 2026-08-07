using Microsoft.AspNetCore.Mvc.Testing;

namespace Undertow.Server.Tests;

public class HealthTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public HealthTests(WebApplicationFactory<Program> factory) => _factory = factory;

    [Fact]
    public async Task Health_IsByteExact()
    {
        using var client = _factory.CreateClient();
        var body = await client.GetStringAsync("/health");
        Assert.Equal("{\"status\":\"ok\"}", body);
    }
}
