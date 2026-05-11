import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getDocumentImageUrl from '@salesforce/apex/PromoDocumentIconHelper.getDocumentImageUrl';

/**
 * Promotions Home tile: shortcut to the "High Usage" Promo_Code__c list view (currently-usable
 * codes with confirmed redemptions, ranked by usage). Renders the branded icon, a description,
 * and an "Open list view" button.
 */
export default class PromoCodeHighUsageWatch extends NavigationMixin(LightningElement) {
    iconUrl;

    @wire(getDocumentImageUrl, { documentName: 'promo_usage' })
    wiredIcon({ data }) {
        this.iconUrl = data || null;
    }

    handleIconError() {
        this.iconUrl = null;
    }

    handleOpen() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Promo_Code__c',
                actionName: 'list'
            },
            state: {
                filterName: 'High_Usage'
            }
        });
    }

    handleKeydown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleOpen();
        }
    }
}
