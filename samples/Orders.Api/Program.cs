using System.Net.Sockets;
using Samples.Shared;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHttpClient("catalog", c =>
    c.BaseAddress = new Uri(builder.Configuration["CATALOG_URL"] ?? "http://catalog-api:8080"));
var app = builder.Build();

var orders = new[]
{
    new Order(1001, ProductId: 1, Quantity: 2),
    new Order(1002, ProductId: 3, Quantity: 1),
};

app.MapGet("/", () => "orders-api");
app.MapGet("/health", () => ServiceInfo.For("orders-api"));

// Service-to-service call over the compose network.
app.MapGet("/orders", async (IHttpClientFactory http) =>
{
    var catalog = http.CreateClient("catalog");
    var result = new List<object>();
    foreach (var o in orders)
    {
        var product = await catalog.GetFromJsonAsync<Product>($"/products/{o.ProductId}");
        result.Add(new { o.Id, o.Quantity, Product = product, Total = product!.Price * o.Quantity });
    }
    return result;
});

// Plain TCP check against the deploy-only postgres (no driver needed offline).
app.MapGet("/db", async (IConfiguration cfg) =>
{
    var host = cfg["DB_HOST"] ?? "db";
    var port = int.Parse(cfg["DB_PORT"] ?? "5432");
    using var tcp = new TcpClient();
    try
    {
        await tcp.ConnectAsync(host, port).WaitAsync(TimeSpan.FromSeconds(3));
        return Results.Ok(new { db = $"{host}:{port}", reachable = true });
    }
    catch (Exception ex)
    {
        return Results.Problem($"{host}:{port} unreachable: {ex.Message}", statusCode: 503);
    }
});

app.Run();

record Order(int Id, int ProductId, int Quantity);
record Product(int Id, string Name, decimal Price);
