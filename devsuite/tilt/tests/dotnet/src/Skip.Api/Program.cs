var app = WebApplication.CreateBuilder(args).Build();
app.MapGet("/", () => $"Skip.Api: {Shared.Lib.Greeting.Text}");
app.Run();
