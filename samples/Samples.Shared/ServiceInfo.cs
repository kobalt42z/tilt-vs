namespace Samples.Shared;

/// <summary>Payload of every sample API's /health endpoint.</summary>
public sealed record ServiceInfo(string Service, string Version, string Configuration, string Host)
{
    // Bump this string to check that a ProjectReference change reaches both APIs.
    public const string SharedVersion = "shared-1";

    public static ServiceInfo For(string service) => new(
        service,
        SharedVersion,
#if DEBUG
        "Debug",
#else
        "Release",
#endif
        Environment.MachineName);
}
