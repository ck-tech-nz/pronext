# Pronext Server Documentation

This directory contains technical documentation for the Pronext Calendar backend system.

## Documentation Index

### Authentication & Security

- **[Pad Authentication](PAD_AUTHENTICATION.md)** - Comprehensive guide on how Pad devices are authenticated, including signature encryption, device SN validation, and accessing pad information in Django API views.

### Service Architecture

- **[Heartbeat Service Migration](HEARTBEAT_SERVICE_MIGRATION.md)** - Documentation on the heartbeat service implementation and migration details.

### Deployment & Operations

- **[Deployment Guide](DEPLOYMENT_GUIDE.md)** - Complete deployment guide covering CI/CD configuration, GitHub Actions workflows, deployment procedures, monitoring, troubleshooting, and rollback strategies.
- **[Django Load Monitoring](DJANGO_LOAD_MONITORING.md)** - Django 负载监控工具使用指南，用于分析系统状态并推荐 Gunicorn 启动参数。

### Data Migration

- **[Public Calendar Migration](PUBLIC_CALENDAR_MIGRATION.md)** - 公共日历（节假日）重复数据迁移方案，将多用户订阅的相同日历合并为公共订阅。

## Documentation Standards

When creating or updating documentation:

1. **Use clear and concise language** - Avoid jargon when possible, explain technical terms when necessary
2. **Provide simple and explicit instructions** - Step-by-step guides are preferred over abstract explanations
3. **Include code examples** - Show practical usage patterns and real-world scenarios
4. **Keep documentation synchronized** - Update docs when code changes
5. **Link to source code** - Reference actual implementation files using relative paths

## Documentation Structure

```text
docs/
├── README.md                              # This file - documentation index
├── PAD_AUTHENTICATION.md                  # Pad device authentication system
├── HEARTBEAT_SERVICE_MIGRATION.md         # Heartbeat service implementation
├── DEPLOYMENT_GUIDE.md                    # Deployment, CI/CD, and operations
├── DJANGO_LOAD_MONITORING.md              # Django load monitoring tool
├── PUBLIC_CALENDAR_MIGRATION.md           # Public calendar deduplication migration
└── sensitive/                             # Sensitive configuration docs (not in version control)
```

## Contributing Documentation

When adding new documentation:

1. Create a descriptive filename in UPPER_SNAKE_CASE.md format
2. Add a link to this README.md under the appropriate category
3. Follow the documentation standards outlined above
4. Include a table of contents for longer documents (>3 sections)
5. Reference source code files using relative paths with line numbers when relevant

## Quick Links

- [Project Overview](../CLAUDE.md) - High-level project information
- [Main README](../README.md) - Project setup and getting started

## Need Help?

If you can't find what you're looking for:

1. Check the [CLAUDE.md](../CLAUDE.md) file for project-specific guidelines
2. Review the source code comments in the relevant modules
3. Contact the development team
