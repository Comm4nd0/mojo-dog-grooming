from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path

from api.views import PasswordResetFormView, PublicIntakeFormView, ThrottledTokenCreateView

urlpatterns = [
    path('admin/', admin.site.urls),
    # The intake form is a web page, not part of the API: it is opened from an
    # emailed link by someone who has no account and no app installed.
    path('intake/<str:token>/', PublicIntakeFormView.as_view(), name='intake-form'),
    path('intake/<str:token>', PublicIntakeFormView.as_view()),
    # Likewise the password reset page: whoever opens it cannot get into the
    # app, so the way back in cannot live inside the app.
    path('reset/<str:token>/', PasswordResetFormView.as_view(), name='password-reset-form'),
    path('reset/<str:token>', PasswordResetFormView.as_view()),
    path('api/', include('api.urls')),
    # Sign-in, ahead of djoser's own route so the tighter throttle applies.
    # Anything below this line would never be reached for this path.
    path('api/auth/token/login/', ThrottledTokenCreateView.as_view(), name='login'),
    # Token login/logout and account management.
    path('api/auth/', include('djoser.urls')),
    path('api/auth/', include('djoser.urls.authtoken')),
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
