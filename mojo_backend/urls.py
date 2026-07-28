from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path

from api.views import PublicIntakeFormView

urlpatterns = [
    path('admin/', admin.site.urls),
    # The intake form is a web page, not part of the API: it is opened from an
    # emailed link by someone who has no account and no app installed.
    path('intake/<str:token>/', PublicIntakeFormView.as_view(), name='intake-form'),
    path('intake/<str:token>', PublicIntakeFormView.as_view()),
    path('api/', include('api.urls')),
    # Token login/logout and account management.
    path('api/auth/', include('djoser.urls')),
    path('api/auth/', include('djoser.urls.authtoken')),
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
