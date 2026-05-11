import { LightningElement } from 'lwc';
import callPSTAPI_Post from '@salesforce/apex/PlaceSalesTransactionTest.callPSTAPI_Post';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

export default class PstApiButton extends NavigationMixin(LightningElement) {
    isLoading = false;

    async handleClick() {
        this.isLoading = true;
        try {
            const orderId = await callPSTAPI_Post();
            if (orderId) {
                this.showToast('Success', 'Order created successfully', 'success');
                // Redirect to the order record on Experience Cloud
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId: orderId,
                        objectApiName: 'Order',
                        actionName: 'view'
                    }
                });
            } else {
                this.showToast('Warning', 'API call completed but no order was created', 'warning');
            }
        } catch (error) {
            this.showToast('Error', error.body?.message || 'An error occurred', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}