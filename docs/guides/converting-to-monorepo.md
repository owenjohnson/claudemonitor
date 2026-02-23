# Converting to a Monorepo

This guide covers when and how to convert a single-package project to a monorepo structure.

## When to Convert

Consider converting when:
- Multiple related packages share code
- You need separate versioning for components
- Team wants independent deployability
- Build times benefit from caching across packages

Don't convert just because:
- "It's the modern way"
- You might need it someday
- Other companies do it

## Prerequisites

- Node.js 18+ (for native workspace support)
- pnpm recommended (or npm/yarn workspaces)

## Step-by-Step Guide

### 1. Install pnpm (if not using)

```bash
npm install -g pnpm
```

### 2. Create Workspace Configuration

Create `pnpm-workspace.yaml`:
```yaml
packages:
  - 'packages/*'
  - 'apps/*'
```

### 3. Restructure Directories

```bash
mkdir -p packages apps

# Move existing code to appropriate location
# Example: move current app to apps/web
mkdir apps/web
git mv src apps/web/
git mv package.json apps/web/
```

### 4. Create Root package.json

```json
{
  "name": "monorepo-root",
  "private": true,
  "scripts": {
    "build": "turbo build",
    "dev": "turbo dev",
    "test": "turbo test"
  },
  "devDependencies": {
    "turbo": "latest"
  }
}
```

### 5. Add Turborepo (Optional but Recommended)

Create `turbo.json`:
```json
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "build": {
      "dependsOn": ["^build"],
      "outputs": ["dist/**"]
    },
    "dev": {
      "cache": false,
      "persistent": true
    },
    "test": {
      "dependsOn": ["build"]
    }
  }
}
```

### 6. Install Dependencies

```bash
pnpm install
```

### 7. Update Imports

If creating shared packages:
```typescript
// Before
import { util } from '../shared/util';

// After
import { util } from '@myorg/shared';
```

### 8. Update CI/CD

Update build commands to use workspace commands:
```yaml
# Before
- run: npm run build

# After
- run: pnpm build --filter=@myorg/web
```

## Directory Structure After

```
monorepo/
├── apps/
│   └── web/              # Main application
│       ├── src/
│       └── package.json
├── packages/
│   └── shared/           # Shared utilities
│       ├── src/
│       └── package.json
├── pnpm-workspace.yaml
├── turbo.json
└── package.json
```

## Common Issues

### Dependency Hoisting
If a package needs a specific version:
```json
{
  "pnpm": {
    "overrides": {
      "package-name": "1.2.3"
    }
  }
}
```

### TypeScript References
Add project references for type checking:
```json
{
  "references": [
    { "path": "../shared" }
  ]
}
```

## Resources

- [pnpm Workspaces](https://pnpm.io/workspaces)
- [Turborepo Documentation](https://turbo.build/repo/docs)
- [npm Workspaces](https://docs.npmjs.com/cli/using-npm/workspaces)
