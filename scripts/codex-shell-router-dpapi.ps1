#requires -Version 7.4
$ErrorActionPreference = 'Stop'
try {
    $encoded = [Console]::In.ReadLine()
    if ([string]::IsNullOrWhiteSpace($encoded)) { throw 'missing_input' }
    $ciphertext = [Convert]::FromBase64String($encoded)
    $plaintext = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $ciphertext, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    [Console]::Out.WriteLine([Convert]::ToBase64String($plaintext))
    [Array]::Clear($plaintext, 0, $plaintext.Length)
} catch {
    [Console]::Error.WriteLine('dpapi_decryption_failed')
    exit 1
}
