import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getDocumentImageUrl from '@salesforce/apex/PromoDocumentIconHelper.getDocumentImageUrl';

/**
 * Promotions Home tile: shortcut to the "Pending Activation" Promo_Code__c list view (Draft
 * status, sorted by most recent). Renders the branded icon, a description, and an "Open list
 * view" button.
 */
export default class PromoCodePendingActivation extends NavigationMixin(LightningElement) {
    iconUrl;

    @wire(getDocumentImageUrl, { documentName: 'pending_activation_promo' })
    wiredIcon({ data }) {
        this.iconUrl = data || null;
    }

    handleOpen() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Promo_Code__c',
                actionName: 'list'
            },
            state: {
                filterName: 'Pending_Activation'
            }
        });
    }
}
