using Documenter
using HardwareLoopProtocol

makedocs(
    sitename = "HardwareLoopProtocol.jl",
    modules = [HardwareLoopProtocol],
    authors = "JuliaGNSS",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://JuliaGNSS.github.io/HardwareLoopProtocol.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Usage" => "usage.md",
        "API Reference" => "api.md",
    ],
    checkdocs = :exports,
)

deploydocs(
    repo = "github.com/JuliaGNSS/HardwareLoopProtocol.jl.git",
    devbranch = "main",
    push_preview = true,
)
