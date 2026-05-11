import { LightningElement } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { RefreshEvent } from 'lightning/refresh';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PromoCodeWizard from 'c/promoCodeWizard';

/**
 * Headless launcher used as the Lightning Web Component override for the standard
 * New action on Promo_Code__c. On mount, opens the PromoCodeWizard modal. After the
 * modal closes successfully, fires a toast (the modal itself can't — LightningModal
 * doesn't surface ShowToastEvent), refreshes the list view, and dismisses the action
 * container.
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
                const count = result.count || 0;
                const action = result.action || 'created';
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Promo Code',
                    message: `${count} promo code${count === 1 ? '' : 's'} ${action}.`,
                    variant: 'success'
                }));
                this.dispatchEvent(new RefreshEvent());
            }
        } catch (e) {
            // swallow — wizard handles its own errors
        } finally {
            this.dispatchEvent(new CloseActionScreenEvent());
        }
    }
}
