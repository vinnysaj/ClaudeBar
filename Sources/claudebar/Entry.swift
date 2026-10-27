import ClaudeBarCLI

@main
enum Entry {
    /// From within an async function the async `main` is the one that runs;
    /// top-level code would pick ArgumentParser's synchronous one.
    static func main() async {
        await ClaudeBarCommand.main()
    }
}
