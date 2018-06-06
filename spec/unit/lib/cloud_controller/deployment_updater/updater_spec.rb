require 'spec_helper'
require 'cloud_controller/deployment_updater/updater'

module VCAP::CloudController
  RSpec.describe DeploymentUpdater::Updater do
    let(:web_process) { ProcessModel.make(instances: 2) }
    let(:webish_process) { ProcessModel.make(app: web_process.app, type: 'web-deployment-guid-1', instances: 5) }

    let!(:deployment) { DeploymentModel.make(app: web_process.app, webish_process: webish_process, state: 'DEPLOYING') }

    let(:deployer) { DeploymentUpdater::Updater }
    let(:diego_instances_reporter) { instance_double(Diego::InstancesReporter) }
    let(:all_instances_results) {
      {
        0 => { state: 'RUNNING', uptime: 50, since: 2 },
        1 => { state: 'RUNNING', uptime: 50, since: 2 },
        2 => { state: 'RUNNING', uptime: 50, since: 2 },
      }
    }
    let(:instances_reporters) { double(:instance_reporters) }

    describe '#update' do
      before do
        allow(CloudController::DependencyLocator.instance).to receive(:instances_reporters).and_return(instances_reporters)
        allow(instances_reporters).to receive(:all_instances_for_app).and_return(all_instances_results)
      end

      context 'when all new webish processes are running' do
        context 'deployments in progress' do
          it 'scales the web process down by one' do
            expect {
              deployer.update
            }.to change {
              web_process.reload.instances
            }.by(-1)
          end

          it 'scales up the new web process by one' do
            expect {
              deployer.update
            }.to change {
              webish_process.reload.instances
            }.by(1)
          end
        end

        context 'the last iteration of deployments in progress' do
          let(:web_process) { ProcessModel.make(instances: 1) }
          let(:webish_process) { ProcessModel.make(app: web_process.app, type: 'web-deployment-guid-1', instances: 5) }

          it 'scales the web process down by one' do
            expect {
              deployer.update
            }.to change {
              web_process.reload.instances
            }.by(-1)
          end

          it 'does not scale up more web processes (one was created with the deployment)' do
            expect {
              deployer.update
            }.not_to change {
              webish_process.reload.instances
            }
          end
        end

        context 'deployments where web process is at zero' do
          before do
            web_process.update(instances: 0)
          end

          it 'replaces the existing web process with the webish process' do
            before_webish_guid = webish_process.guid
            before_web_guid = web_process.guid

            deployer.update

            after_web_process = deployment.reload.app.web_process
            after_webish_process = deployment.reload.webish_process

            expect(after_web_process.guid).to eq(before_webish_guid)
            expect(after_web_process.instances).to eq(5)
            expect(ProcessModel.find(guid: before_web_guid)).to be_nil
            expect(after_webish_process).to be_nil
          end
        end
      end

      context 'when the deployment is in state DEPLOYED' do
        let(:finished_web_process) { ProcessModel.make(instances: 0) }
        let(:finished_webish_process) { ProcessModel.make(instances: 2) }
        let!(:finished_deployment) { DeploymentModel.make(app: finished_web_process.app, webish_process: finished_webish_process, state: 'DEPLOYED') }

        it 'does not scale the deployment' do
          expect {
            deployer.update
          }.not_to change {
            finished_web_process.reload.instances
          }

          expect {
            deployer.update
          }.not_to change {
            finished_webish_process.reload.instances
          }
        end
      end

      context 'when one of the webish instances is starting' do
        let(:all_instances_results) {
          {
            0 => { state: 'RUNNING', uptime: 50, since: 2 },
            1 => { state: 'STARTING', uptime: 50, since: 2 },
            2 => { state: 'STARTING', uptime: 50, since: 2 },
          }
        }

        it 'does not scales the process' do
          expect {
            deployer.update
          }.not_to change {
            web_process.reload.instances
          }

          expect {
            deployer.update
          }.not_to change {
            webish_process.reload.instances
          }
        end
      end

      context 'when one of the webish instances is failing' do
        let(:all_instances_results) {
          {
            0 => { state: 'RUNNING', uptime: 50, since: 2 },
            1 => { state: 'FAILING', uptime: 50, since: 2 },
            2 => { state: 'FAILING', uptime: 50, since: 2 },
          }
        }

        it 'does not scale the process' do
          expect {
            deployer.update
          }.not_to change {
            web_process.reload.instances
          }

          expect {
            deployer.update
          }.not_to change {
            webish_process.reload.instances
          }
        end
      end

      context 'when diego is unavailable' do
        before do
          allow(instances_reporters).to receive(:all_instances_for_app).and_raise(CloudController::Errors::ApiError.new_from_details('InstancesUnavailable', 'omg it broke'))
        end

        it 'does not scale the process' do
          expect {
            deployer.update
          }.not_to change {
            web_process.reload.instances
          }

          expect {
            deployer.update
          }.not_to change {
            webish_process.reload.instances
          }
        end
      end
    end
  end
end
