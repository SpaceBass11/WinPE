# Manifest mode

Manifest mode allows repeatable task-based imaging from a JSON file.

## Parameters

- `-ManifestFile <path>`: enables manifest mode.
- `-TaskName <name>`: run a specific task directly.
- `-ListTasks`: print available tasks and exit.

## Required structure

```json
{
  "tasks": {
    "Task Name": {
      "wim": "win11-standard.wim",
      "index": 1
    }
  }
}
```

## Optional structure

```json
{
  "tasks": {
    "Win11-Standard": {
      "wim": "win11-standard.wim",
      "index": 1,
      "drivers": "drivers/win11/Latitude5440",
      "unattend": "unattend/win11.xml",
      "disklayout": "custom-disk-layouts/gpt-standard.txt"
    }
  },
  "models": {
    "Latitude 5440": [
      "Win11-Standard"
    ]
  }
}
```

> Current implementation uses `wim` and optional `index` for deployment selection. Other keys are reserved for future phases.

## Path resolution rules

Task `wim` values are resolved in this order:

1. As provided relative to the manifest folder
2. As `wim/<value>` relative to the manifest folder

Absolute paths are used as-is.

