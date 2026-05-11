import { LightningElement } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { RefreshEvent } from 'lightning/refresh';
import PromoCodeWizard from 'c/promoCodeWizard';

/**
 * Headless launcher LWC used as the Lightning Component override for the standard
 * New action on Promo_Code__c. When the user clicks "New" on the list view,
 * Salesforce instantiates this component; on connected, it immediately opens the
 * PromoCodeWizard modal. When the modal closes, this fires CloseActionScreenEvent
 * to dismiss the action container and RefreshEvent so the list view re-queries.
 */
export default class PromoCodeWizardButton extends LightningElement {
    _opened = false;

    async connectedCallback() {
        if (this._opened) return;
        this._opened = true;
        try {
            const result = await PromoCodeWizard.open({
                size: 'medium',
                label: 'New Promo Code'
            });
            if (result && result.result === 'created') {
                this.dispatchEvent(new RefreshEvent());
            }
        } catch (e) {
            // swallow — wizard handles its own errors via toast; nothing to do here
        } finally {
            this.dispatchEvent(new CloseActionScreenEvent());
        }
    }
}
