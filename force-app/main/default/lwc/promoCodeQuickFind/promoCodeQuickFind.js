import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import findByCode from '@salesforce/apex/PromoCodeQuickFindController.findByCode';
import getDocumentImageUrl from '@salesforce/apex/PromoDocumentIconHelper.getDocumentImageUrl';

/**
 * Promotions Home tile: Quick Find Promo Code. Member-of-staff searches a code by exact value;
 * on a single match the LWC navigates to that record, on multi-currency match it renders an
 * inline picker.
 *
 * Icon: Document `quick_find_promo` (GBTA Logos folder). Falls back to utility:search if the
 * Document is absent.
 *
 * Public API: none — the tile is self-contained.
 */
export default class PromoCodeQuickFind extends NavigationMixin(LightningElement) {
    searchTerm = '';
    lastSearched = '';
    results = [];
    isLoading = false;
    hasSearched = false;
    iconUrl;

    @wire(getDocumentImageUrl, { documentName: 'quick_find_promo' })
    wiredIcon({ data }) {
        this.iconUrl = data || null;
    }

    get showResults() {
        return !this.isLoading && this.results.length > 0;
    }

    get showNoMatch() {
        return !this.isLoading && this.hasSearched && this.results.length === 0;
    }

    get clearDisabled() {
        return this.isLoading || (!this.searchTerm && !this.hasSearched);
    }

    handleIconError() {
        this.iconUrl = null;
    }

    handleInput(event) {
        this.searchTerm = event.target.value;
    }

    handleKeydown(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            this.handleSearch();
        }
    }

    handleRowKeydown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleSelect(event);
        }
    }

    async handleSearch() {
        const term = (this.searchTerm || '').trim();
        if (!term) {
            this.results = [];
            this.hasSearched = false;
            return;
        }
        this.isLoading = true;
        this.lastSearched = term;
        try {
            const data = await findByCode({ searchTerm: term });
            this.results = (data || []).map((r) => ({
                ...r,
                statusClass: this._statusClass(r.status, r.isCurrentlyUsable)
            }));
            this.hasSearched = true;
            // Single match: jump straight to the record.
            if (this.results.length === 1) {
                this._navigate(this.results[0].recordId);
            }
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('PromoCodeQuickFind: findByCode failed', err);
            this.results = [];
            this.hasSearched = true;
        } finally {
            this.isLoading = false;
        }
    }

    handleSelect(event) {
        const recordId = event.currentTarget.dataset.id;
        if (recordId) this._navigate(recordId);
    }

    handleClear() {
        this.searchTerm = '';
        this.lastSearched = '';
        this.results = [];
        this.hasSearched = false;
    }

    _navigate(recordId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                objectApiName: 'Promo_Code__c',
                actionName: 'view'
            }
        });
    }

    _statusClass(status, isUsable) {
        if (status === 'Active' && isUsable) return 'status-badge status-badge--active';
        if (status === 'Active') return 'status-badge status-badge--expired';
        return 'status-badge status-badge--draft';
    }
}
