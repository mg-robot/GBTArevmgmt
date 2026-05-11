import { LightningElement, api } from 'lwc';
import searchProducts from '@salesforce/apex/PromoCodeService.searchProducts';

import LBL_SearchLabel from '@salesforce/label/c.PromoCodeWizard_PP_Search_Label';
import LBL_SearchPlaceholder from '@salesforce/label/c.PromoCodeWizard_PP_SearchPlaceholder';
import LBL_Searching from '@salesforce/label/c.PromoCodeWizard_PP_Searching';
import LBL_SelectedTemplate from '@salesforce/label/c.PromoCodeWizard_PP_SelectedTemplate';

/**
 * Multi-select picker for Specific Products scope.
 *
 * Storage (current): CSV of Product Names in Specific_Products__c — matches the
 * PromoCodeAllocationEngine which matches against Product2.Name.
 *
 * Display: search results show "Product Code — Product Name" so staff can disambiguate
 * by code. Switching the persisted CSV to codes is a follow-up (would require updating
 * the allocation engine too).
 */
export default class PromoSpecificProductPicker extends LightningElement {
    @api initialCsv = '';

    searchTerm = '';
    results = [];
    selected = [];
    loading = false;

    label = {
        searchLabel: LBL_SearchLabel,
        searchPlaceholder: LBL_SearchPlaceholder,
        searching: LBL_Searching
    };

    connectedCallback() {
        if (this.initialCsv) {
            const names = this.initialCsv
                .split(',')
                .map((s) => s.trim())
                .filter(Boolean);
            this.selected = names.map((n) => ({ name: n, label: n }));
        }
    }

    get hasResults() {
        return this.results && this.results.length > 0;
    }

    get hasSelected() {
        return this.selected.length > 0;
    }

    get selectedHeader() {
        return LBL_SelectedTemplate.replace('{0}', this.selected.length);
    }

    handleSearch(e) {
        this.searchTerm = e.target.value || '';
        if (this.searchTerm.length < 2) {
            this.results = [];
            return;
        }
        this.loading = true;
        searchProducts({ searchTerm: this.searchTerm })
            .then((r) => {
                const taken = new Set(this.selected.map((s) => s.name));
                this.results = (r || []).filter((p) => !taken.has(p.name));
            })
            .catch(() => {
                this.results = [];
            })
            .finally(() => {
                this.loading = false;
            });
    }

    addProduct(e) {
        const name = e.currentTarget.dataset.name;
        if (!name) return;
        if (!this.selected.some((s) => s.name === name)) {
            this.selected = [...this.selected, { name, label: name }];
            this.fireChange();
        }
        this.results = this.results.filter((r) => r.name !== name);
    }

    removeProduct(e) {
        const name = e.target.name;
        this.selected = this.selected.filter((s) => s.name !== name);
        this.fireChange();
    }

    fireChange() {
        const csv = this.selected.map((s) => s.name).join(',');
        this.dispatchEvent(
            new CustomEvent('change', { detail: { csv, count: this.selected.length } })
        );
    }
}
