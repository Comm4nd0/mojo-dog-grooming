from django.apps import AppConfig


class ApiConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'api'
    # The admin groups every model under the app's label, so without this the
    # index and every breadcrumb read "API" — the one place the whole thing
    # still announced itself as plumbing rather than as Jess's records.
    verbose_name = 'Grooming records'
