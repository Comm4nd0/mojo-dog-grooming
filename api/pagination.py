"""One paginator for every list endpoint.

DRF's ``PageNumberPagination`` **ignores** ``?page_size=`` unless
``page_size_query_param`` names it — and the default class never does. The
app had been asking for 200 breeds a page since the breed list existed and
getting 100 back, silently: no error, no ``next`` followed, just the first
hundred names in alphabetical order and nothing after them. Jess's *"Not all
the breeds are showing on the breed list… I've updated it on the database
but not showing on the app"* was every breed past the letter the hundredth
one happened to start with.

``max_page_size`` is the ceiling on what a caller may ask for. It is a guard
against a runaway query, not a quota — the whole breed table is a few hundred
rows and a reference list is exactly the thing that wants to arrive whole.
"""

from rest_framework.pagination import PageNumberPagination


class MojoPagination(PageNumberPagination):
    page_size = 100
    page_size_query_param = 'page_size'
    max_page_size = 1000
