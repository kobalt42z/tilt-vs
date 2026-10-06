namespace Shared.Lib;

public static class Greeting
{
    // The e2e check edits this string and expects the running container to change
    // through publish + sync + restart, without an image rebuild.
    public const string Text = "hello v1";
}
