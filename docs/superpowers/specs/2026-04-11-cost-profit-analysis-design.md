# Cost-Profit Analysis System Design

**Date:** 2026-04-11
**Status:** Approved
**Type:** New independent project (separate repo)

## Purpose

Personal tool for analyzing Pronext business financials — tracking costs, revenue, profit trends, and simulating pricing/cost changes to inform investment and pricing decisions.

## Revenue & Cost Model

**Revenue:** One-time software license sales.

```
actual_sales = license_count * license_unit_price
monthly_revenue = max(actual_sales, guaranteed_minimum)
```

The guaranteed minimum varies month to month.

**Cost categories (preset, user-extensible):**
- Server / cloud services
- Hardware / materials
- Labor
- AI subscriptions

**Profit:** `revenue - sum(all costs)`

## Data Sources

- Manual entry (primary)
- Bank statement Excel import (parse, preview, user classifies each line, aggregate by month)
- Future: auto-pull from cloud provider billing APIs (AWS, GCP, Cloudflare) — architecture reserves extension point, not built in v1

## Data Model

### CostCategory

| Field        | Type   | Description                                            |
| ------------ | ------ | ------------------------------------------------------ |
| id           | int    | PK                                                     |
| name         | string | Category name                                          |
| auto_source  | string | Nullable. Future: `aws`, `gcp`, `cloudflare` for auto-pull |
| sort_order   | int    | Display order                                          |
| is_default   | bool   | Whether this is a preset category                      |

### MonthlyRecord

| Field               | Type    | Description                                    |
| ------------------- | ------- | ---------------------------------------------- |
| id                  | int     | PK                                             |
| year_month          | string  | `YYYY-MM` format, unique                       |
| license_count       | int     | Licenses sold this month                       |
| license_unit_price  | decimal | Unit price this month                          |
| guaranteed_minimum  | decimal | Guaranteed minimum revenue this month          |
| revenue             | decimal | Stored, computed on save: `max(count * price, guaranteed_min)` |
| note                | text    | Optional notes                                 |

### MonthlyCost

| Field       | Type    | Description                          |
| ----------- | ------- | ------------------------------------ |
| id          | int     | PK                                   |
| record_id   | int     | FK -> MonthlyRecord                  |
| category_id | int     | FK -> CostCategory                   |
| amount      | decimal | Cost amount                          |
| note        | text    | Optional notes                       |

### SimulationScenario

| Field  | Type   | Description                                     |
| ------ | ------ | ----------------------------------------------- |
| id     | int    | PK                                              |
| name   | string | e.g., "Price +10% scenario"                     |
| params | JSON   | `{price_pct, count_pct, min_adjust, costs: {category_id: pct}}` |

## Architecture

```
+----------------------------------+
|        Vue 3 SPA (Vite)          |
|  ECharts + Element Plus          |
|  Port 5173 (dev)                 |
+-----------------+----------------+
                  | REST API
                  v
+----------------------------------+
|        FastAPI Backend           |
|  Port 8100                       |
|  /api/records     CRUD           |
|  /api/categories  CRUD           |
|  /api/import      Excel parse    |
|  /api/forecast    Trend predict  |
|  /api/simulate    What-if        |
+-----------------+----------------+
                  |
                  v
+----------------------------------+
|           SQLite                 |
|  finance.db                      |
+----------------------------------+
```

### Backend Stack

- FastAPI + Uvicorn
- SQLAlchemy (ORM) + Alembic (migrations)
- openpyxl (Excel parsing)
- numpy (linear regression for trend forecasting)

### Frontend Stack

- Vue 3 + Vite + TypeScript
- ECharts (charts, dark theme)
- Element Plus (UI components: tables, forms, sliders — dark override)
- axios

### UI Design Direction — SpaceX-inspired

Reference: spacex.com modern aesthetic.

- **Dark theme**: near-black background (#0A0A0A), high-contrast white/light-gray text
- **Typography**: clean sans-serif (Inter or similar), thin weight for headings, generous letter-spacing
- **Layout**: full-width sections, large whitespace, geometric grid
- **Color**: minimal — monochrome base with a single accent color (e.g., blue #2563EB) for key metrics and interactive elements
- **Charts**: dark canvas, subtle gridlines, glowing accent lines, no chart borders
- **Cards**: semi-transparent dark panels with subtle border (#1A1A1A), no heavy shadows
- **Animations**: smooth fade/slide transitions between views, chart data entry animations
- **Numbers**: large, bold display for key metrics (revenue, profit), small muted labels

### Deployment

- Dev: separate frontend/backend dev servers
- Prod: `vite build` outputs static files, FastAPI serves them — single process

## Pages & Features

### 1. Dashboard (Home)

- Current month profit overview card (revenue, total cost, net profit)
- Trailing 12-month profit trend line chart
- Cost category breakdown pie chart
- Visual indicator when revenue hits guaranteed minimum floor

### 2. Monthly Data Management

- List of months, click to edit
- Edit form: license count, unit price, guaranteed minimum, cost per category
- Revenue auto-calculated: `max(count * price, guaranteed_min)`
- Default: new month inherits previous month's guaranteed_minimum

### 3. Excel Import

- Upload bank statement Excel file (column mapping configurable — different banks have different formats)
- System parses and displays preview table
- User assigns each line item to a cost category (or skips irrelevant items)
- On confirm: aggregates by month and writes to corresponding MonthlyRecord/MonthlyCost

### 4. What-if Simulation

- Parameter panel with sliders/inputs:
  - License unit price: +/- %
  - License count: +/- %
  - Guaranteed minimum: absolute adjustment
  - Per-category cost: +/- % (individually or uniformly)
- Real-time chart (computed in frontend, no backend call):
  - Gray line = current trend forecast
  - Colored line = adjusted forecast
  - Horizontal dashed line = guaranteed minimum floor
  - Break-even point annotated
- Summary card: avg profit next 6 months, profit margin change, whether guaranteed minimum is triggered
- Save/load named scenarios for comparison

### 5. Trend Forecast

- Linear regression on historical monthly data (minimum 3 months required)
- Separate forecasts: revenue trend, per-category cost trends
- Projects 6 months forward with confidence interval (shaded band)
- Shows "insufficient data" message when < 3 months
- Integrated into same chart view as What-if simulation

## Extension Points (Not Built in v1)

- `/api/providers` route space reserved for cloud billing API integrations
- `CostCategory.auto_source` field reserved for automated cost collection
- Multi-currency support (not needed now — single currency)
