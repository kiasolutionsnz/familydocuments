package main

import "testing"

func TestResolveDocumentCategoryUsesRentalsCollectionAlias(t *testing.T) {
	categories := []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}{
		{ID: "records", Name: "Rental records"},
		{ID: "rentals", Name: "Rentals"},
	}
	for _, requested := range []string{"rental", "Rentals", "this as rental document", "rental property"} {
		id, name, matches := resolveDocumentCategory(requested, categories)
		if id != "rentals" || name != "Rentals" || len(matches) != 0 {
			t.Fatalf("%q resolved to %q %q %#v", requested, id, name, matches)
		}
	}
}

func TestResolveDocumentCategoryReportsAmbiguity(t *testing.T) {
	categories := []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}{
		{ID: "home", Name: "Home"},
		{ID: "records", Name: "Home records"},
	}
	id, _, matches := resolveDocumentCategory("home records archive", categories)
	if id != "" || len(matches) != 2 {
		t.Fatalf("expected two choices, got %q %#v", id, matches)
	}
}

func TestResolveDocumentCategoryReportsSingularPluralAmbiguity(t *testing.T) {
	categories := []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}{
		{ID: "singular", Name: "Rental"},
		{ID: "plural", Name: "Rentals"},
	}
	id, _, matches := resolveDocumentCategory("rental", categories)
	if id != "" || len(matches) != 2 {
		t.Fatalf("expected both real Family categories, got %q %#v", id, matches)
	}
}

func TestResolveDocumentCategoryDoesNotCrossMissingFamilyList(t *testing.T) {
	categories := []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}{{ID: "home", Name: "Home"}}
	id, _, matches := resolveDocumentCategory("Rentals", categories)
	if id != "" || len(matches) != 0 {
		t.Fatalf("missing Family category unexpectedly resolved: %q %#v", id, matches)
	}
}
