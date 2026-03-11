Run a quick syntax check on unified_winpe_deploy.ps1:

1. Use pwsh to tokenize the script and report any parse errors
2. Check that all braces, parentheses, and string delimiters are balanced
3. Verify the script can be parsed without errors
4. Report results concisely

Run this command:
```
pwsh -NoProfile -Command "& ./tests/test_parse.ps1"
```

If pwsh is not available, manually check the script structure for obvious issues.
