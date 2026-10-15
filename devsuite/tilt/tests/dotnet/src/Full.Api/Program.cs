var app = WebApplication.CreateBuilder(args).Build();
app.MapGet("/", () => $"Full.Api: {Shared.Lib.Greeting.Text}");
app.Run();
