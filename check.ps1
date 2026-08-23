$ErrorActionPreference = "Stop"

if (-not (Get-Command stylua -ErrorAction SilentlyContinue)) {
    Write-Host "Error: 'stylua' is not installed or not in your PATH." -ForegroundColor Red
    Write-Host "Please install StyLua to format the code (e.g., via 'cargo install stylua' or downloading from GitHub)." -ForegroundColor Yellow
    exit 1
}

if (-not (Get-Command luacheck -ErrorAction SilentlyContinue)) {
    Write-Host "Error: 'luacheck' is not installed or not in your PATH." -ForegroundColor Red
    Write-Host "Please install Luacheck to lint the code (e.g., via 'luarocks install luacheck')." -ForegroundColor Yellow
    exit 1
}

Write-Host "Formatting Lua files with StyLua..."
stylua .

Write-Host "Linting Lua files with Luacheck..."
luacheck .

Write-Host "All checks passed!" -ForegroundColor Green
