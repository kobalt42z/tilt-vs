using Samples.Shared;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var products = new Dictionary<int, Product>
{
    [1] = new(1, "Keyboard", 49.90m),
    [2] = new(2, "Mouse", 19.90m),
    [3] = new(3, "Monitor", 219.00m),
};

app.MapGet("/", () => "catalog-api");
app.MapGet("/health", () => ServiceInfo.For("catalog-api"));
app.MapGet("/products", () => products.Values);
app.MapGet("/products/{id:int}", (int id) =>
    products.TryGetValue(id, out var p) ? Results.Ok(p) : Results.NotFound());

app.Run();

record Product(int Id, string Name, decimal Price);
