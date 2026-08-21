import BenchmarkCore
import Foundation

@main
struct DocumentKitBenchmarkCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] || arguments == ["-h"] {
                FileHandle.standardOutput.write(Data(BenchmarkCommandLine.usage.utf8))
                Foundation.exit(0)
            }
            let configuration = try BenchmarkCommandLine.configuration(arguments: arguments)
            let bundle = try await BenchmarkRunner.run(configuration)
            try BenchmarkRunner.write(bundle, to: configuration.outputURL)
            FileHandle.standardOutput.write(Data(bundle.shareableText.utf8))
        } catch let failure as BenchmarkFailure {
            fail(with: failure.code)
        } catch {
            fail(with: BenchmarkFailure.internalRunnerFailure.code)
        }
    }

    private static func fail(with code: String) -> Never {
        FileHandle.standardError.write(Data("documentkit-benchmark failed [\(code)]\n".utf8))
        Foundation.exit(1)
    }
}
