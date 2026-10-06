# See https://aka.ms/customizecontainer to learn how to customize your debug container.

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
USER $APP_UID
WORKDIR /app
EXPOSE 8080

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG BUILD_CONFIGURATION=Release
WORKDIR /src
COPY ["Skip.Api/Skip.Api.csproj", "Skip.Api/"]
COPY ["Shared.Lib/Shared.Lib.csproj", "Shared.Lib/"]
COPY ["Directory.Build.props", "./"]
RUN dotnet restore "./Skip.Api/Skip.Api.csproj"
COPY . .
WORKDIR "/src/Skip.Api"
RUN dotnet build "./Skip.Api.csproj" -c $BUILD_CONFIGURATION -o /app/build

FROM build AS publish
ARG BUILD_CONFIGURATION=Release
RUN dotnet publish "./Skip.Api.csproj" -c $BUILD_CONFIGURATION -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "Skip.Api.dll"]
