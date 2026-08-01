from django.urls import include, path
from rest_framework.routers import DefaultRouter

from . import views

router = DefaultRouter()
router.register('accounts', views.AccountViewSet, basename='account')
router.register('password-resets', views.PasswordResetViewSet, basename='password-reset')
router.register(
    'password-reset-requests', views.PasswordResetRequestViewSet, basename='password-reset-request',
)
router.register('clients', views.ClientViewSet, basename='client')
router.register('claim-requests', views.ClientClaimRequestViewSet, basename='claim-request')
router.register('dogs', views.DogViewSet, basename='dog')
router.register('problem-areas', views.ProblemAreaViewSet, basename='problem-area')
router.register('dog-photos', views.DogPhotoViewSet, basename='dog-photo')
router.register('breeds', views.BreedViewSet, basename='breed')
router.register('appointments', views.AppointmentViewSet, basename='appointment')
router.register('booking-series', views.BookingSeriesViewSet, basename='booking-series')
router.register('groom-sessions', views.GroomSessionViewSet, basename='groom-session')
router.register('invoices', views.InvoiceViewSet, basename='invoice')
router.register('payments', views.PaymentViewSet, basename='payment')
router.register('equipment', views.EquipmentViewSet, basename='equipment')
router.register('todos', views.TodoItemViewSet, basename='todo')
router.register('opening-hours', views.OpeningHoursViewSet, basename='opening-hours')
router.register('closures', views.ClosureDayViewSet, basename='closure')
router.register('temperament-grades', views.TemperamentGradeViewSet, basename='temperament-grade')
router.register('intake-invites', views.IntakeInviteViewSet, basename='intake-invite')
router.register('intake-submissions', views.IntakeSubmissionViewSet, basename='intake-submission')

urlpatterns = [
    path('health/', views.health, name='health'),
    path('me/', views.MyProfileView.as_view(), name='my-profile'),
    path('settings/', views.AppSettingsView.as_view(), name='app-settings'),
    # Public, token-authenticated intake form — no login.
    path('intake/<str:token>/', views.PublicIntakeView.as_view(), name='public-intake'),
    # Setting a new password from a reset link — no login either, by definition.
    path('password-reset/<str:token>/', views.PublicPasswordResetView.as_view(), name='public-password-reset'),
    path('', include(router.urls)),
]
