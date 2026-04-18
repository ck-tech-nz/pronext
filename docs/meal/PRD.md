# APIs

This document describes the APIs for the meal module.

## Architecture

The meal module follows DRY principles with shared components:

```
pronext/meal/
├── models.py           # Database models
├── options.py          # Shared business logic
├── serializers.py      # Shared serializers
├── rrule_utils.py      # RFC 5545 RRULE utilities
├── viewset_base.py     # Base ViewSet mixins (for Pad)
├── viewset_pad.py      # Pad API endpoints (/pad-api/)
└── viewset_app.py      # App API endpoints (/app-api/)
```

### API Endpoints

| Client | Base URL | Authentication | Device ID |
|--------|----------|----------------|-----------|
| Android Pad | `/pad-api/meal/` | Device signature + JWT | From JWT token |
| Vue3 WebView | `/app-api/meal/device/{device_id}/` | JWT only | From URL path |

Both endpoints share the same:
- Serializers (request/response format)
- Business logic (options.py)
- Database models

## Implementation Notes

When a device user is created, default meal categories and recipes are automatically created through a Django signal.

Admins can configure default categories and recipes in the Django admin panel under:

- **Default Category Templates**: Configure default category names, colors, and order
- **Default Recipe Templates**: Configure default recipes for each category

Changes to default templates only affect newly created device users. Existing users' data is not modified.

## Category

The meal categories are different from the calendar categories.

Each user has their own meal categories, but default to four categories: Breakfast, Lunch, Dinner, Snack.

Users can modify category's name and color and change to show/hide, but cannot delete or add new category.

### Default Categories

Default categories with colors:

```python
Breakfast (#FF6B6B)
Lunch (#4ECDC4)
Dinner (#45B7D1)
Snack (#FFA07A)
```

### Category Models

```python
class Category(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    name = models.CharField(max_length=255)
    color = models.CharField(max_length=255, default="#000000")
    is_hidden = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
```

### Get Category List

```
GET /pad-api/meal/category/list                        # Pad
GET /app-api/meal/device/{device_id}/category/list     # App (Vue3 WebView)
```

Response:

```json
[
  {
    "id": 1,
    "name": "Breakfast",
    "color": "#FF6B6B",
    "is_hidden": false
  }
]
```

### Update Category

Update category's name and color and change to show/hide.

```
POST /pad-api/meal/category/{category_id}/update                        # Pad
POST /app-api/meal/device/{device_id}/category/{category_id}/update     # App
```

Request body:

```json
{
  "name": "Breakfast",
  "color": "#000000",
  "is_hidden": true
}
```

## Recipe

### Default Recipes

#### Breakfast

- Bagels
- Eggs
- Milk & Cereal
- Oatmeal
- Pancakes
- Yogurt
- Fruit
- Juice
- Coffee
- Tea
- Water

#### Lunch

- Grilled Cheese
- Leftover
- Pizza
- Salad
- Soup
- Wraps

#### Dinner

- Burger
- Eat Out
- Hot Dog
- Pizza
- Spaghetti
- Takeout

#### Snack

- Fruit
- Juice
- Coffee
- Tea
- Water
- Snack
- Candy
- Chocolate
- Ice Cream
- Cookies
- Chips

with default name and description that can be set by admin in default model

### Recipe Models

```python
class Recipe(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    name = models.CharField(max_length=255)
    category = models.ForeignKey(Category, on_delete=models.CASCADE)
    description = models.TextField(blank=True, null=True)
    calorie = models.PositiveIntegerField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
```

### Get Recipe List of a category

```
GET /pad-api/meal/recipe/category/{category_id}/list                        # Pad
GET /app-api/meal/device/{device_id}/recipe/category/{category_id}/list     # App
```

Response:

```json
[
  {
    "id": 1,
    "name": "Eggs",
    "description": "",
    "calorie": 155,
    "category": 1,
    "created_at": "2025-10-14T06:45:00Z"
  }
]
```

### Add Recipe

Add a recipe to a category.

```
POST /pad-api/meal/recipe/add                        # Pad
POST /app-api/meal/device/{device_id}/recipe/add     # App
```

Request body:

```json
{
  "category": 1,
  "name": "Recipe 1",
  "description": "Description 1",
  "calorie": 200
}
```

Response:

```json
{
  "id": 35
}
```

### Update Recipe

Update a recipe.

```
PUT /pad-api/meal/recipe/{recipe_id}/update                        # Pad
PUT /app-api/meal/device/{device_id}/recipe/{recipe_id}/update     # App
```

Request body:

```json
{
  "name": "Recipe 1",
  "description": "Description 1",
  "calorie": 200
}
```

### Delete Recipe

Delete a recipe.

```
DELETE /pad-api/meal/recipe/{recipe_id}/delete                        # Pad
DELETE /app-api/meal/device/{device_id}/recipe/{recipe_id}/delete     # App
```

## Meal

### Design Concept

Each Meal represents ONE recipe planned for a specific date. For multi-item meals (e.g., "eggs and bacon"), create multiple Meal records with the same plan_date.

### Meal Models

```python
class Meal(models.Model):
    user = ForeignKey(AUTH_USER_MODEL, on_delete=CASCADE)
    recipe = ForeignKey(Recipe, on_delete=CASCADE)
    note = TextField(blank=True, null=True)
    plan_date = DateField()

    # RFC 5545 RRULE (stored internally, e.g., "FREQ=DAILY;INTERVAL=1")
    rrule = CharField(max_length=512, blank=True, null=True)
    # RFC 5545 EXDATE (excluded dates as ISO strings)
    exdates = JSONField(default=list)
```

### Recurrence Rules

The API uses a **structured repeat object** for input/output, which is automatically converted to/from RFC 5545 RRULE for internal storage.

#### Repeat Object Format

```json
{
  "freq": "daily",         // daily | weekly | monthly | yearly
  "interval": 1,           // every N days/weeks/months/years (default: 1)
  "until": "2025-12-31",   // optional end date (ISO format)
  "byday": ["MO", "WE", "FR"],  // weekdays for weekly/monthly (SU,MO,TU,WE,TH,FR,SA)
  "bymonthday": 15,        // day of month for monthly
  "bysetpos": 3            // occurrence for monthly (1-4 or -1 for last)
}
```

#### Repeat Pattern Examples

| Pattern | repeat Object |
|---------|--------------|
| Daily | `{"freq": "daily"}` |
| Every 2 days | `{"freq": "daily", "interval": 2}` |
| Weekly on Mon/Wed/Fri | `{"freq": "weekly", "byday": ["MO", "WE", "FR"]}` |
| Monthly on 15th | `{"freq": "monthly", "bymonthday": 15}` |
| Monthly on 3rd Monday | `{"freq": "monthly", "byday": ["MO"], "bysetpos": 3}` |
| Monthly on last Friday | `{"freq": "monthly", "byday": ["FR"], "bysetpos": -1}` |
| Yearly | `{"freq": "yearly"}` |
| With end date | `{"freq": "daily", "until": "2025-12-31"}` |

### Get Meal List

Get meals for a date range (for weekly/monthly views).

```
GET /pad-api/meal/list?start_date=2025-10-14&end_date=2025-10-20                        # Pad
GET /app-api/meal/device/{device_id}/list?start_date=2025-10-14&end_date=2025-10-20     # App
```

Response:

```json
[
  {
    "id": 1,
    "category_id": 1,
    "recipe": "Oatmeal",
    "calorie": 150,
    "plan_date": "2025-10-14",
    "has_repeat": true,
    "repeat_flag": "2025-10-14"
  }
]
```

### Get Meal Detail

```
GET /pad-api/meal/{meal_id}/detail                        # Pad
GET /app-api/meal/device/{device_id}/{meal_id}/detail     # App
```

Response:

```json
{
  "id": 1,
  "category_id": 1,
  "recipe": "Oatmeal",
  "calorie": 150,
  "note": "My daily breakfast",
  "plan_date": "2025-10-14",
  "has_repeat": true,
  "repeat": {
    "freq": "daily",
    "interval": 1
  },
  "repeat_flag": "2025-10-14"
}
```

### Add Meal

```
POST /pad-api/meal/add                        # Pad
POST /app-api/meal/device/{device_id}/add     # App
```

Request body (no repeat):

```json
{
  "recipe": 5,
  "note": "My breakfast",
  "plan_date": "2025-10-14"
}
```

Request body (with repeat):

```json
{
  "recipe": 5,
  "note": "My daily breakfast",
  "plan_date": "2025-10-14",
  "repeat": {
    "freq": "daily",
    "interval": 1,
    "until": "2025-12-31"
  }
}
```

Response:

```json
{
  "id": 1
}
```

### Update Meal

For non-repeating meals, simply update the fields.

For repeating meals, must include `change_type`:

- `change_type`: 0=THIS, 1=ALL, 2=AND_FUTURE
- `repeat_flag`: Required for THIS (0) and AND_FUTURE (2), not needed for ALL (1)

```
PUT /pad-api/meal/{meal_id}/update                        # Pad
PUT /app-api/meal/device/{device_id}/{meal_id}/update     # App
```

#### Basic Updates

Request body (update all instances - updates the ONE database record directly):

```json
{
  "recipe": 5,
  "note": "Updated note",
  "plan_date": "2025-10-14",
  "change_type": 1
}
```

Request body (update only this instance - creates new record, adds date to exdates):

```json
{
  "recipe": 6,
  "note": "Different meal today",
  "plan_date": "2025-10-14",
  "change_type": 0,
  "repeat_flag": "2025-10-14"
}
```

Request body (update this and future - creates new record, sets UNTIL on old):

```json
{
  "recipe": 5,
  "note": "New meal from now on",
  "plan_date": "2025-10-14",
  "repeat": {
    "freq": "daily",
    "interval": 1
  },
  "change_type": 2,
  "repeat_flag": "2025-10-14"
}
```

#### Turn Repeat On/Off

Turn repeat off:

```json
{
  "recipe": 5,
  "note": "No longer repeating",
  "plan_date": "2025-10-14",
  "repeat": null
}
```

Turn repeat on (daily example):

```json
{
  "recipe": 5,
  "note": "Now repeats daily",
  "plan_date": "2025-10-14",
  "repeat": {
    "freq": "daily",
    "interval": 1
  }
}
```

#### Repeat Examples

**Daily Repeat**: Every N days starting from plan_date

```json
{
  "recipe": 5,
  "plan_date": "2025-10-14",
  "repeat": {
    "freq": "daily",
    "interval": 2,
    "until": "2025-12-31"
  }
}
```

**Weekly Repeat**: Every N weeks on selected weekdays

```json
{
  "recipe": 5,
  "plan_date": "2025-10-14",
  "repeat": {
    "freq": "weekly",
    "interval": 1,
    "byday": ["MO", "WE", "FR"]
  }
}
```

**Monthly Repeat (by day of month)**: Every N months on the same date

```json
{
  "recipe": 5,
  "plan_date": "2025-10-15",
  "repeat": {
    "freq": "monthly",
    "interval": 1,
    "bymonthday": 15
  }
}
```

**Monthly Repeat (by weekday)**: Every N months on the Nth weekday

```json
{
  "recipe": 5,
  "plan_date": "2025-10-14",
  "repeat": {
    "freq": "monthly",
    "interval": 1,
    "byday": ["MO"],
    "bysetpos": 3
  }
}
```

**Monthly Repeat (last weekday)**: Every N months on the last weekday

```json
{
  "recipe": 5,
  "plan_date": "2025-10-25",
  "repeat": {
    "freq": "monthly",
    "interval": 1,
    "byday": ["FR"],
    "bysetpos": -1
  }
}
```

**Yearly Repeat**: Every N years on the same date

```json
{
  "recipe": 5,
  "plan_date": "2025-10-14",
  "repeat": {
    "freq": "yearly",
    "interval": 1
  }
}
```

### Delete Meal

For non-repeating meals, simply delete.

For repeating meals, must include `change_type`:

- `repeat_flag`: Required for THIS (0) and AND_FUTURE (2), not needed for ALL (1)

```
DELETE /pad-api/meal/{meal_id}/delete                        # Pad
DELETE /app-api/meal/device/{device_id}/{meal_id}/delete     # App
```

Request body (delete all instances - deletes the database record):

```json
{
  "change_type": 1
}
```

Request body (delete only this instance - adds date to exdates):

```json
{
  "change_type": 0,
  "repeat_flag": "2025-10-14"
}
```

Request body (delete this and future - sets UNTIL in rrule):

```json
{
  "change_type": 2,
  "repeat_flag": "2025-10-14"
}
```
